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
    @Published var listings: [Listing] = []
    @Published var renders: [UUID: Render] = [:]      // listingID → render

    let api: APIClient = MockAPIClient()

    func load() async {
        if listings.isEmpty {
            listings = (try? await api.listings()) ?? []
        }
    }

    func add(_ listing: Listing) {
        listings.insert(listing, at: 0)
    }

    func setStatus(_ status: Listing.Status, for id: UUID) {
        guard let i = listings.firstIndex(where: { $0.id == id }) else { return }
        listings[i].status = status
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
