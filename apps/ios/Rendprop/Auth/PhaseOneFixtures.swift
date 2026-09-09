#if DEBUG
import SwiftUI
import UIKit

/// Only entered by the dedicated loopback-network test on a disposable simulator.
/// It seeds media/state, then renders the real production screen and buttons.
struct PhaseOneFixtureRoot: View {
    @EnvironmentObject var model: AppModel
    @State private var fixture: Listing?
    @State private var error: String?
    private var surface: String { ProcessInfo.processInfo.environment["RENDP_TEST_SURFACE"] ?? "publish" }

    var body: some View {
        Group {
            if let listing = fixture {
                switch surface {
                case "photo":
                    NavigationStack { PhotoStudioView(listing: listing, entry: .studio) }
                case "aerial":
                    AerialIntroSheet(listing: listing)
                case "reel":
                    ReelStudioView(listing: listing, photos: EnhancedPhoto.loadAll(listingID: listing.id))
                default:
                    NavigationStack {
                        RenderStatusView(listing: listing,
                            render: Render(listingID: listing.id, tier: .smooth, durationS: 1))
                    }
                }
            } else if let error {
                Text(error).accessibilityIdentifier("phase1.fixture.error")
            } else {
                ProgressView("Preparing isolated fixture")
            }
        }
        .task {
            guard fixture == nil, error == nil, let base = Config.sessionTestURL else { return }
            do {
                // The fixture server is loopback-only; no provider is involved.
                let (media, response) = try await URLSession.shared.data(from: base.appendingPathComponent("clip.mp4"))
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                var listing = Listing(address: "Network Test Workspace", beds: 2, baths: 1,
                                      sqft: 1000, price: Money(cents: 0))
                listing.serverID = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
                listing.latitude = 0; listing.longitude = 0
                listing.status = .ready
                let dir = EnhancedPhoto.directory(for: listing.id)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let video = dir.appendingPathComponent("fixture.mp4")
                try media.write(to: video, options: .atomic)
                if surface != "publish" {
                    for index in 0..<2 {
                        let image = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 160)).image { context in
                            (index == 0 ? UIColor.blue : UIColor.green).setFill()
                            context.fill(CGRect(x: 0, y: 0, width: 160, height: 160))
                        }
                        try image.jpegData(compressionQuality: 0.8)!.write(
                            to: dir.appendingPathComponent("enh-fixture-\(index).jpg"), options: .atomic)
                    }
                    listing.exteriorPhotoRelPath = FileStore.relativePath(for: dir.appendingPathComponent("enh-fixture-0.jpg"))
                }
                model.listings = [listing]
                model.tours[listing.id] = AppModel.RenderedTour(url: video, durationS: 1, speedFactor: 1)
                model.uploadedRenderAssets[listing.id] = .init(
                    relPath: FileStore.relativePath(for: video), assetID: "10000000-0000-4000-8000-000000000002")
                // Consent belongs to the fixture, not to a real person's data.
                AIConsent.shared.grant()
                fixture = listing
            } catch {
                self.error = "Fixture preparation failed: \(error.localizedDescription)"
            }
        }
    }
}
#endif
