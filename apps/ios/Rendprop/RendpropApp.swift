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

    let api: APIClient = MockAPIClient()

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

        // 2. Append fresh sample listings (never persisted; deduped by address).
        let samples = ((try? await api.listings()) ?? []).filter { $0.isSample }
        for sample in samples where !listings.contains(where: { $0.isSample && $0.address == sample.address }) {
            listings.append(sample)
        }
    }

    func add(_ listing: Listing) {
        listings.insert(listing, at: 0)   // persists via didSet
    }

    func setStatus(_ status: Listing.Status, for id: UUID) {
        guard let i = listings.firstIndex(where: { $0.id == id }) else { return }
        listings[i].status = status       // persists via didSet
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

    private struct PersistedAsset: Codable {
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

    private struct PersistedTour: Codable {
        var relPath: String
        var durationS: Double
        var speedFactor: Double
    }

    private struct PersistedState: Codable {
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

// MARK: - Entry
@main
struct RendpropApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model = AppModel()
    @StateObject private var uploads = UploadManager.shared
    @AppStorage("hasOnboarded") private var hasOnboarded = false

    var body: some Scene {
        WindowGroup {
            Group {
                if hasOnboarded {
                    HomeListingsView()
                } else {
                    OnboardingView()
                }
            }
            .environmentObject(model)
            .environmentObject(uploads)
            .tint(Theme.accent)
            .preferredColorScheme(.light)  // Rendprop is light, clean, white + purple
        }
    }
}
