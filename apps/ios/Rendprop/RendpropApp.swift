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
