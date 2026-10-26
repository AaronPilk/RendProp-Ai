import SwiftUI
import UIKit
import Photos
import PhotosUI
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import MapKit
import CoreLocation
import RoomPlan
import QuickLook
import simd
import UniformTypeIdentifiers
import AVFoundation   // Reel Studio: composition + stitch + export
import AVKit          // Reel Studio / Aerial intro: VideoPlayer preview
import CryptoKit

/// Retains one feature tap while anonymous session creation reconnects. A
/// second tap cannot enqueue the same paid action twice, and leaving the
/// feature cancels only this waiter, not another screen's shared signup.
@MainActor
private final class FeatureSessionAction: ObservableObject {
    @Published private(set) var isWaiting = false
    private var task: Task<Void, Never>?
    private var generation = UUID()

    func run(_ action: @escaping @MainActor () -> Void) {
        guard task == nil else { return }
        let attempt = UUID()
        generation = attempt
        isWaiting = true
        task = Task { [weak self] in
            let connected = await AuthStore.shared.ensureSession()
            guard let self, self.generation == attempt else { return }
            self.task = nil
            self.isWaiting = false
            guard connected, !Task.isCancelled else { return }
            action()
        }
    }

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        isWaiting = false
    }
}

/// The workspace's remembered answer to "List this tour on Google".
///
/// WHY A REMEMBERED DEFAULT AT ALL. The hosted page is `noindex, nofollow`
/// until its owner opts in, and that is right: it carries their name, phone,
/// e-mail and a street address. But an agent who wants their listings findable
/// wants ALL of them findable, and making them answer the same question on
/// every tour is how a good default becomes a chore people click through.
///
/// So: OFF for a workspace that has never answered, then whatever they last
/// chose. Per WORKSPACE, not per install — a phone that signs into a different
/// account starts at OFF again rather than inheriting a stranger's answer,
/// which is the only direction it is safe to be wrong in. It is a local
/// convenience, never the published state: what the page does is decided by the
/// listing's own `allowSearchIndexing`, which is what actually gets sent.
enum SearchIndexingDefault {
    private static let valueKey = "tour.searchIndexing.default"

    /// The current workspace's identity, as far as this device can tell.
    /// Empty before any session exists — which reads as "not the workspace
    /// that saved a default", i.e. OFF.
    @MainActor private static var owner: String {
        guard let actor = AuthStore.shared.userID, !actor.isEmpty,
              let org = WorkspaceContext.selectedOrgID else { return "" }
        return "\(actor.lowercased()):\(org.uuidString.lowercased())"
    }

    @MainActor static var value: Bool {
        let defaults = UserDefaults.standard
        guard !owner.isEmpty else { return false }
        return defaults.bool(forKey: valueKey + "." + owner)
    }

    @MainActor static func remember(_ allowed: Bool) {
        // Actor-only entries from older builds cannot opt another workspace
        // into indexing. They read OFF until a choice is made in this scope.
        guard !owner.isEmpty else { return }
        let defaults = UserDefaults.standard
        defaults.set(allowed, forKey: valueKey + "." + owner)
    }
}

/// A concrete card keeps its modifier metadata behind one named View type.
/// The layout, gradient, AI badge and dimming are shared by every tool tile.
private struct ListingToolCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorSchemeContrast) private var contrast
    let title: String
    let sub: String
    let icon: String
    let gradient: LinearGradient
    var ai = false
    var dimmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(dimmed ? Theme.disabledInk : Color.white)
                    .frame(width: 40, height: 40)
                    .background {
                        if dimmed { RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.disabledFill) }
                        else { RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.18)) }
                    }
                    .accessibilityHidden(true)
                Spacer()
                if ai {
                    Text("AI").font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .foregroundStyle(dimmed ? Theme.disabledInk : Color.white)
                        .background(dimmed ? Theme.disabledFill : Color.black.opacity(contrast == .increased ? 0.5 : 0.4), in: Capsule())
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.rpBody.weight(.semibold))
                    .foregroundStyle(dimmed ? Theme.disabledInk : Color.white)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                Text(sub)
                    .font(.rpCaption)
                    .foregroundStyle(dimmed ? Theme.disabledInk : Color.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: dynamicTypeSize.isAccessibilitySize ? nil : 136, alignment: .topLeading)
        .background {
            let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
            if dimmed { shape.fill(Theme.disabledFill) }
            else {
                shape.fill(gradient)
                    // Keep the original gradient visible. A smooth lower scrim
                    // supports white labels without separate text panels.
                    .overlay {
                        GeometryReader { geometry in
                            let height = max(geometry.size.height, 1)
                            LinearGradient(stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .black.opacity(contrast == .increased ? 0.48 : 0.34), location: min(64 / height, 1)),
                                .init(color: .black.opacity(contrast == .increased ? 0.48 : 0.34), location: 1)
                            ], startPoint: .top, endPoint: .bottom)
                        }
                        .clipShape(shape)
                        .allowsHitTesting(false)
                    }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
            .strokeBorder(dimmed ? Theme.border : Color.white.opacity(0.26),
                          lineWidth: contrast == .increased ? 1.5 : 0.75))
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: Theme.ink.opacity(0.06), radius: 10, y: 4)
    }
}

/// All link tiles have the same small concrete type. Destinations are erased
/// only inside NavigationLink's builder, so constructing the grid does not
/// preconstruct screens or perform their appearance/file/network work.
private struct ListingToolLinkTile: View {
    let card: ListingToolCard
    let disabled: Bool
    let accessibilityID: String
    let destination: () -> AnyView

    var body: some View {
        NavigationLink { destination() } label: { card }
            .buttonStyle(ScalePressStyle())
            .disabled(disabled)
            .accessibilityIdentifier(accessibilityID)
    }
}

private struct ListingToolButtonTile: View {
    let card: ListingToolCard
    let disabled: Bool
    let accessibilityID: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { card }
            .buttonStyle(ScalePressStyle())
            .disabled(disabled)
            .accessibilityIdentifier(accessibilityID)
    }
}

/// This is deliberately a card, not a disabled NavigationLink: a remote tour
/// cannot be rendered again until its exact source is present on this phone.
private struct ListingToolUnavailableTile: View {
    var body: some View {
        ListingToolCard(title: "Re-render fly-through", sub: "Needs the source video on this phone",
                        icon: "arrow.clockwise", gradient: RPGradient.drone, dimmed: true)
            .accessibilityLabel("Re-render fly-through unavailable. Download the source video from Cloud files or add it to this phone.")
            .accessibilityIdentifier("detail.rerenderUnavailable")
    }
}

/// Only app-owned raw recording/import paths can supply a room-tag timeline.
/// A rendered tour, photo video, cloud render or bundled sample is not a take.
enum RoomTagWalkthroughPolicy {
    static func sourceURL(asset: CaptureAsset?, documents: URL, isSample: Bool,
                          isCurrent: Bool, generatedURLs: [URL] = []) -> URL? {
        guard isCurrent, !isSample, let asset, asset.localURL.isFileURL,
              asset.durationS.isFinite, asset.durationS >= 0.2, asset.durationS <= 600,
              asset.fps.isFinite, asset.fps > 0, asset.width > 0, asset.height > 0,
              asset.bytes > 0 else { return nil }
        let url = asset.localURL.standardizedFileURL
        let base = documents.standardizedFileURL
        guard !generatedURLs.contains(where: {
            $0.standardizedFileURL.resolvingSymlinksInPath() == url.resolvingSymlinksInPath()
        }) else { return nil }
        let parent = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        let isRecording = parent == base.appendingPathComponent("Recordings", isDirectory: true)
            && name.hasPrefix("walkthrough-") && url.pathExtension.lowercased() == "mov"
        let importPrefix = "import-"
        let importParts = String(name.dropFirst(importPrefix.count)).split(separator: "-", maxSplits: 1)
        let isImport = parent == base.appendingPathComponent("Imports", isDirectory: true)
            && name.hasPrefix(importPrefix) && importParts.count == 2
            && importParts[0].utf8.count == 8 && importParts[0].utf8.allSatisfy({
                (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
            })
            && !importParts[1].isEmpty
        guard isRecording || isImport else { return nil }
        let rawDirectory = isRecording ? "Recordings" : "Imports"
        guard parent.resolvingSymlinksInPath() == base.resolvingSymlinksInPath()
            .appendingPathComponent(rawDirectory, isDirectory: true) else { return nil }
        // Older demo imports had real CaptureAsset rows. Their source name
        // still identifies the bundled demo rather than the owner's footage.
        let originalName = isImport ? String(importParts[1]).lowercased() : name.lowercased()
        guard !["demo.mp4", "sample.mp4", "sample-tour.mp4", "demo-tour.mp4"].contains(originalName),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, Int64(size) == asset.bytes else { return nil }
        return url
    }
}

private struct ListingToolboxGrid: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let listing: Listing
    // Preserve the detail screen's live read when a destination is built.
    let destinationListing: () -> Listing
    let space: SpaceType
    let asset: CaptureAsset?
    let canRerender: Bool
    let canTagRooms: Bool
    let hasPublishedTour: Bool
    let photoCount: Int
    let openReel: () -> Void
    let openRoomTagger: () -> Void
    /// Build 60: one tap for the whole listing — tour, photos, originals,
    /// disclosures, videos and a details note — as one ZIP (TestFlight 59:
    /// "the share all feature is supposed to be the FULL package").
    let sharePackage: () -> Void
    let hasAnythingToShare: Bool

    private var sample: Bool { listing.isSample }
    private var createFirst: String { "Create a \(space.spaceNoun) first" }
    private var photosSub: String {
        photoCount == 0 ? "Add and brighten" : "\(photoCount) photo\(photoCount == 1 ? "" : "s") · add more"
    }

    var body: some View {
        LazyVGrid(columns: dynamicTypeSize.isAccessibilitySize
                  ? [GridItem(.flexible())] : [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            // Photo management and AI edits remain separate entry points.
            ListingToolLinkTile(
                card: ListingToolCard(title: "Photos", sub: sample ? createFirst : photosSub,
                                      icon: "photo.stack", gradient: RPGradient.photo, dimmed: sample),
                disabled: sample, accessibilityID: "detail.photos",
                destination: { AnyView(PhotoStudioView(listing: destinationListing(), entry: .photos)) }
            )
            ListingToolLinkTile(
                card: ListingToolCard(title: "AI Photo Studio", sub: sample ? createFirst : "Declutter · staging · sky",
                                      icon: "wand.and.stars", gradient: RPGradient.photo, ai: true, dimmed: sample),
                disabled: sample, accessibilityID: "detail.photoStudio",
                destination: { AnyView(PhotoStudioView(listing: destinationListing(), entry: .studio)) }
            )
            // The existing detail-owned cover reads live photos/aerial on tap.
            ListingToolButtonTile(
                card: ListingToolCard(title: "Make a video", sub: sample ? createFirst : "Social media or listing",
                                      icon: "film.stack", gradient: RPGradient.reel, ai: true, dimmed: sample),
                disabled: sample, accessibilityID: "detail.reelStudio", action: openReel
            )
            ListingToolLinkTile(
                card: ListingToolCard(title: "Drone-style walkthrough", sub: sample ? createFirst : "Optional · record or upload",
                                      icon: "video", gradient: RPGradient.drone, dimmed: sample),
                disabled: sample, accessibilityID: "detail.recordedWalkthrough",
                destination: { AnyView(RecordedWalkthroughView(listing: destinationListing())) }
            )
            ListingToolButtonTile(
                card: ListingToolCard(title: space == .realEstate ? "Tag rooms" : "Tag areas",
                                      sub: sample ? createFirst : (canTagRooms ? "Tap-to-jump chapters" : "Add walkthrough first"),
                                      icon: "mappin.and.ellipse", gradient: RPGradient.rooms, dimmed: !canTagRooms || sample),
                disabled: sample, accessibilityID: "detail.roomTags", action: openRoomTagger
            )
            // Main tools keep four paired rows. The optional re-render action
            // follows the grid so an existing walkthrough never leaves an orphan.
            ListingToolLinkTile(
                card: ListingToolCard(title: "Aerial intro", sub: sample ? createFirst : "Front of home · opening only",
                    icon: "airplane.departure", gradient: RPGradient.aerial, dimmed: sample),
                disabled: sample, accessibilityID: "detail.aerialOpening",
                destination: { AnyView(AerialOpeningScreen(listing: destinationListing())) }
            )
            // One entry for plans and measurements, and one for room tours.
            // Only the explicit TestFlight lab creates either destination.
#if SPATIAL_CAPTURE_LAB
            ListingToolLinkTile(
                card: ListingToolCard(title: "Floor plans & measurements", sub: sample ? createFirst : "Scan · measure · upload",
                                      icon: "ruler", gradient: RPGradient.plan, dimmed: sample),
                disabled: sample, accessibilityID: "detail.floorPlanLab",
                destination: { AnyView(FloorPlanView(listing: destinationListing())) }
            )
            ListingToolLinkTile(
                card: ListingToolCard(title: "3D tours", sub: sample ? createFirst : "Capture & explore rooms",
                                      icon: "rotate.3d", gradient: RPGradient.drone, dimmed: sample),
                disabled: sample, accessibilityID: "detail.spatialLab",
                destination: { AnyView(SpatialTestingHubView(listing: destinationListing())) }
            )
#else
            ListingToolCard(title: "Floor plans & measurements", sub: "Coming soon",
                            icon: "ruler", gradient: RPGradient.plan, dimmed: true)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("detail.measurementsComingSoon")
            ListingToolCard(title: "3D tours", sub: "Coming soon",
                            icon: "rotate.3d", gradient: RPGradient.drone, dimmed: true)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("detail.spatialComingSoon")
#endif
        }
    }

    /// Optional walkthrough actions stay full-width after the paired tools.
    @ViewBuilder var rerenderTile: some View {
        if !sample, hasPublishedTour {
            if let asset, canRerender {
                ListingToolLinkTile(
                    card: ListingToolCard(title: "Re-render fly-through", sub: "New render · new sharing link",
                                          icon: "arrow.clockwise", gradient: RPGradient.drone),
                    disabled: false, accessibilityID: "detail.rerenderTour",
                    destination: { AnyView(ReviewSubmitView(listing: destinationListing(), asset: asset)) }
                )
            } else {
                ListingToolUnavailableTile()
            }
        }
    }

    /// The section places sharing after every tool as one full-width row.
    var sharePackageTile: ListingToolButtonTile {
        ListingToolButtonTile(
            card: ListingToolCard(title: "Share everything",
                                  sub: sample ? createFirst : (hasAnythingToShare ? "On this iPhone · photos · videos · one ZIP" : "Add photos or a tour first"),
                                  icon: "shippingbox.fill", gradient: RPGradient.share, dimmed: sample || !hasAnythingToShare),
            disabled: sample || !hasAnythingToShare, accessibilityID: "detail.sharePackage", action: sharePackage
        )
    }
}

private struct RecordedWalkthroughView: View {
    let listing: Listing
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var auth = AuthStore.shared
    @ObservedObject private var workspace = WorkspaceStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var scope = NativePresentationScope(actorID: AuthStore.shared.userID, orgID: WorkspaceContext.selectedOrgID)
    private var currentListing: Listing { model.listings.first(where: { $0.id == listing.id }) ?? listing }
    private var isCurrent: Bool {
        scope.matches(actorID: auth.userID, orgID: WorkspaceContext.selectedOrgID) &&
        model.listings.contains { $0.id == listing.id && $0.cloudUnavailable != true && model.isInSelectedWorkspace($0) }
    }
    private var tour: AppModel.RenderedTour? { model.tours[listing.id] }
    private var asset: CaptureAsset? { model.assets[listing.id] }
    private var roomTags: [RoomTag] {
        let speed = tour?.speedFactor ?? 1
        guard speed.isFinite, speed > 0 else { return [] }
        return (asset?.roomTags ?? []).map { RoomTag(name: $0.name, tMs: Int((Double($0.tMs) / speed).rounded())) }
    }
    var body: some View {
        ScrollView {
            if isCurrent {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                Text("Optional recorded walkthrough").font(.rpTitle).foregroundStyle(Theme.ink)
                Text("Record on your phone or upload existing walkthrough or drone footage. Walk slowly, keep the camera level and steady, and turn gently around corners. A phone gimbal can help smooth doorways and turns.")
                    .font(.rpBody).foregroundStyle(Theme.inkDim)
                if let url = tour?.url ?? asset?.localURL {
                    PlayerWebView(localVideoURL: url, roomTags: roomTags, listing: currentListing)
                        .frame(height: 460).clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                }
                NavigationLink { AddVideoFlowView(listing: currentListing) } label: {
                    Label("Record or upload footage", systemImage: "video.badge.plus")
                        .font(.rpBody.weight(.semibold)).frame(maxWidth: .infinity).padding(14)
                        .modifier(RendpropActionLabelSurface(primary: true))
                }.buttonStyle(ScalePressStyle()).accessibilityIdentifier("walkthrough.addFootage")
                if let asset {
                    NavigationLink { ReviewSubmitView(listing: currentListing, asset: asset) } label: {
                        Label("Review and create the walkthrough", systemImage: "sparkles")
                    }.accessibilityIdentifier("walkthrough.review")
                }
                Text("This recorded video stays separate from the photo-based listing presentation. Adding footage doesn't replace your chosen property video.")
                    .font(.rpCaption).foregroundStyle(Theme.inkDim)
            }.padding()
            } else { Text("Your account or listing changed. Reopen the walkthrough from your listing.").padding() }
        }.background(Theme.bg).navigationTitle("Drone-style walkthrough").navigationBarTitleDisplayMode(.inline)
        .onChange(of: auth.userID) { _ in if !isCurrent { dismiss() } }
        .onChange(of: workspace.selected?.id) { _ in if !isCurrent { dismiss() } }
    }
}

private struct ListingToolboxSection: View {
    let grid: ListingToolboxGrid
    let resumeAerial: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("TOOLBOX").font(.rpKicker).foregroundStyle(Theme.inkDim)
                .frame(maxWidth: .infinity, alignment: .leading)
            grid
            grid.rerenderTile
            if let resumeAerial {
                Button(action: resumeAerial) {
                    Label("Resume earlier aerial", systemImage: "arrow.clockwise")
                        .font(.rpBody.weight(.semibold)).foregroundStyle(Theme.accent)
                }
                .accessibilityHint("Checks the request already submitted. Does not generate a new aerial.")
                .accessibilityIdentifier("detail.resumeAerial")
            }
            grid.sharePackageTile
        }
    }
}

#if targetEnvironment(simulator)
/// Cold-launch regression fixture for the real detail screen, including Release
/// builds. It is unavailable in device archives and requires the offline UI-test
/// flag. It never restores/persists a customer's library or invokes capture/AI.
struct DetailMetadataRegressionHost: View {
    private static let cases: Set<String> = ["empty", "capture", "rich", "missing-source",
                                             "published-no-source", "sample", "venue", "republish", "republish-stale"]
    static var requestedCase: String? {
        guard Config.isUITesting else { return nil }
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-ui.detailMetadataFixture"),
              index + 1 < arguments.count, cases.contains(arguments[index + 1]) else { return nil }
        return arguments[index + 1]
    }

    @EnvironmentObject private var model: AppModel
    @State private var listing: Listing?
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 0) {
            if Self.requestedCase == "republish-stale", let listing,
               let current = model.listings.first(where: { $0.id == listing.id }) {
                Text("Warning: \(current.lastError ?? "none")")
                    .accessibilityIdentifier("build59.fixture.warning")
                Text(current.shareURL ?? "missing link")
                    .accessibilityIdentifier("build59.fixture.link")
            }
            if Config.isUITesting && ProcessInfo.processInfo.arguments.contains("-ui.photoWorkFixture") {
                PhotoWorkBanner()
            }
            NavigationStack {
                if let listing {
                    FlythroughDetailView(listing: listing)
                        .toolbar {
                            if Self.requestedCase == "republish" {
                                ToolbarItem(placement: .navigationBarLeading) {
                                    NavigationLink("Fixture Settings") { SettingsView() }
                                        .accessibilityIdentifier("build58.fixture.settings")
                                }
                            }
                        }
                } else if let failure {
                    Text(failure).accessibilityIdentifier("detail.fixtureFailure")
                } else {
                    ProgressView("Preparing synthetic detail fixture")
                }
            }
        }
        .task {
            guard listing == nil, failure == nil, let requested = Self.requestedCase else { return }
            do { try await seed(requested) }
            catch { failure = "Synthetic fixture failed: \(error.localizedDescription)" }
        }
    }

    @MainActor private func seed(_ name: String) async throws {
        var value = Listing(address: "Detail fixture \(name)", beds: 3, baths: 2,
                            sqft: 1800, price: Money(cents: 45_000_000))
        value.spaceTypeRaw = name == "venue" ? SpaceType.venue.rawValue : SpaceType.realEstate.rawValue
        value.isSample = name == "sample"
        // Infinity keeps synthesized Hashable reflexive; mapCoordinate rejects
        // it as nonfinite. hasCoordinate + region still prevents geocoding, so
        // this offline fixture needs no MapKit tile/geocoder request.
        value.latitude = .infinity; value.longitude = .infinity; value.regionLabel = "Synthetic fixture"
        value.clientContactLoaded = true
        if name == "rich" {
            value.clientContact = ListingClientContact(listingID: value.id, enabled: true,
                publicCard: ClientPublicCard(name: "Fixture client", brokerage: "Fixture agency"),
                recipientEmail: "fixture@example.invalid")
        }
        // Exact simulator-only extension of the existing offline republish host.
        // UUID provenance is synthetic, never issued by a production backend.
        // MockAPIClient has no PhotoFeedbackAPI transport, so UI feedback stays
        // on this simulator and cannot send a provider or production request.
        let photoFeedbackFixture = name == "republish" && Config.isOfflineAccountFixture
            && (model.api is MockAPIClient)
            && ProcessInfo.processInfo.arguments.contains("-ui.photoFeedbackFixture")
        let hasCapture = ["capture", "rich", "missing-source", "venue"].contains(name)
        let hasTour = ["rich", "missing-source", "venue"].contains(name)
        let hasAerial = ["rich", "missing-source"].contains(name)
        let photoCount = name == "rich" || photoFeedbackFixture ? 3 : (["missing-source", "published-no-source", "venue"].contains(name) ? 1 : 0)
        var video: URL?
        if hasCapture || hasTour || hasAerial {
            video = try await Self.makeSyntheticVideo(listingID: value.id)
        }
        if hasCapture, let video {
            let source: URL
            if name == "missing-source" {
                source = FileStore.recordingsDir.appendingPathComponent("missing-fixture-\(value.id).mp4")
            } else {
                source = try await Self.makeSyntheticVideo(listingID: value.id, rawRecording: true)
            }
            let sourceBytes = name == "missing-source" ? FileStore.fileSize(video) : FileStore.fileSize(source)
            model.assets[value.id] = CaptureAsset(localURL: source, durationS: 2, fps: 10,
                                                 width: 64, height: 64, bytes: sourceBytes)
        }
        if hasTour, let video {
            model.tours[value.id] = AppModel.RenderedTour(url: video, durationS: 2, speedFactor: 1.25)
            value.status = .ready
        }
        if ["published-no-source", "republish", "republish-stale"].contains(name) {
            // A syntactically valid fake share link selects the share branch.
            // The suite never opens a browser, QR, share sheet or publish action.
            value.shareSlug = "metadata-fixture"
            value.shareURL = "https://example.invalid/f/metadata-fixture"
            value.status = .ready
        }
        if hasAerial, let video {
            let aerial = FileStore.aerialsDir.appendingPathComponent("\(value.id)-fixture.mp4")
            try FileManager.default.copyItem(at: video, to: aerial)
            value.aerialRelPath = FileStore.relativePath(for: aerial)
            value.aerialGeneratedAt = Date()
        }
        if photoCount > 0 {
            let directory = EnhancedPhoto.directory(for: value.id)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let legacyPhotoPairs = name == "rich" && Config.isOfflineAccountFixture
                && (model.api is MockAPIClient)
                && ProcessInfo.processInfo.arguments.contains("-ui.legacyPhotoPairs")
            for index in 0..<photoCount {
                let image = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 480)).image { context in
                    UIColor(hue: CGFloat(index) / 3, saturation: 0.35, brightness: 0.8, alpha: 1).setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
                    UIColor.white.setFill(); context.fill(CGRect(x: 80, y: 100, width: 480, height: 280))
                }
                guard let jpeg = image.jpegData(compressionQuality: 0.85) else { throw FixtureError.image }
                let id = "fixture-\(index)"
                if legacyPhotoPairs {
                    // Real pre-history pairs stay unverified; the normal rich fixture is unchanged.
                    try PhotoCaptureStorage.writePair(original: jpeg, enhanced: jpeg, id: id, directory: directory)
                } else if name == "rich" || photoFeedbackFixture, index == 0 {
                    let base = "fixture-base-0"
                    try PhotoVersionHistory.saveCapture(original: jpeg, enhanced: jpeg, id: base, directory: directory)
                    _ = try PhotoVersionHistory.saveEdit(jpeg: jpeg, id: id, parentID: base, sourceID: base,
                        edit: "stage", style: "modern", disclosure: "Virtually staged synthetic UI fixture.",
                        provenanceID: photoFeedbackFixture ? UUID().uuidString : nil,
                        provenanceRecorded: photoFeedbackFixture, directory: directory)
                    try PhotoVersionHistory.select(id: id, directory: directory, reviewed: true)
                } else {
                    try PhotoVersionHistory.saveCapture(original: jpeg, enhanced: jpeg, id: id, directory: directory)
                }
            }
        }
        if ["republish", "republish-stale"].contains(name) {
            guard model.api is MockAPIClient else { throw FixtureError.image }
            try WorkspaceStore.shared.prepareBuild58FixtureLibrary()
            // Feedback UI uses local synthetic media, not a fabricated cloud
            // selection. Existing republish cases retain their remote identity.
            value.serverID = photoFeedbackFixture ? nil : UUID(uuidString: "b5800000-0000-4000-8000-000000000001")
            value.serverOrgID = photoFeedbackFixture ? nil : WorkspaceContext.selectedOrgID
            value.cloudSyncOwnerID = photoFeedbackFixture ? nil : AuthStore.shared.userID.flatMap(UUID.init(uuidString:))
            if photoFeedbackFixture {
                // A detached local copy cannot auto-create a cloud draft. The
                // real guard remains unchanged; no fake remote mapping exists.
                value.cloudDetachedServerID = UUID()
            }
            value.needsServerSync = false
            if name == "republish-stale" { value.lastError = "stale" }
        }
        // AppModel.load is deliberately never called by this host. Its
        // hasLoaded guard keeps these transient fixtures out of PersistentStore.
        model.listings = [value]
        listing = value
    }

    private enum FixtureError: Error { case image, video }

    /// Procedural silent video: no camera, microphone, bundled house footage or
    /// remote asset. It exercises real AVFoundation/PlayerWebView metadata.
    @MainActor private static func makeSyntheticVideo(listingID: UUID, rawRecording: Bool = false) async throws -> URL {
        // A recorded source and its rendered tour have separate identities.
        let name = rawRecording ? "walkthrough-metadata-fixture-\(listingID).mov" : "metadata-fixture-\(listingID).mp4"
        let url = FileStore.recordingsDir.appendingPathComponent(name)
        let writer = try AVAssetWriter(outputURL: url, fileType: rawRecording ? .mov : .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                                         kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
        guard writer.canAdd(input) else { throw FixtureError.video }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? FixtureError.video }
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32ARGB, nil, &buffer) == kCVReturnSuccess,
              let buffer else { throw FixtureError.video }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let address = CVPixelBufferGetBaseAddress(buffer) {
            memset(address, 120, CVPixelBufferGetBytesPerRow(buffer) * 64)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        for index in 0..<20 {
            var checks = 0
            while !input.isReadyForMoreMediaData, checks < 300 {
                try await Task.sleep(nanoseconds: 10_000_000)
                checks += 1
            }
            guard input.isReadyForMoreMediaData,
                  adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 10)) else {
                writer.cancelWriting(); throw writer.error ?? FixtureError.video
            }
        }
        input.markAsFinished()
        await withCheckedContinuation { continuation in writer.finishWriting { continuation.resume() } }
        guard writer.status == .completed else { throw writer.error ?? FixtureError.video }
        return url
    }
}
#endif

struct FlythroughDetailView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var auth = AuthStore.shared
    @ObservedObject private var workspace = WorkspaceStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var presentationScope = NativePresentationScope(
        actorID: AuthStore.shared.userID, orgID: WorkspaceContext.selectedOrgID)
    // LOAD-BEARING: the business type drives every noun, the Zillow/sold gating
    // and which listings exist at all. Switching type while this screen is
    // pushed used to leave a HOUSE open inside Gym mode, still showing
    // "Mark as sold" and the Zillow field (found in the simulator sweep).
    // Observing it both re-renders the copy and pops the screen when this
    // listing no longer belongs to the selected industry.
    @AppStorage("space.type") private var spaceTypeRaw = SpaceType.realEstate.rawValue
    let listing: Listing
    /// Land ON the photo library instead of on this screen.
    ///
    /// Set only by the "Start with photos" path on the create screen. A working
    /// agent's first run: she created a listing, was handed a video button and
    /// nothing else, and found photos only by scrolling down to the toolbox
    /// afterwards. When photos are what she asked for, photos are what opens —
    /// once, so backing out of them lands here rather than bouncing straight
    /// back in.
    var openPhotosOnAppear: Bool = false

    @State private var zillowText = ""
    @State private var zillowSeeded = false
    @State private var zillowError: String?
    @State private var showRoomTagger = false
    @State private var showRoomTagsWalkthroughHelp = false
    @State private var showWalkthroughForRoomTags = false
    @State private var availableRoomTagAsset: CaptureAsset?
    /// Drives the photos screen when this view was opened photos-first.
    @State private var showPhotosScreen = false
    @State private var didAutoOpenPhotos = false
    @State private var tagsBeforeEdit: [RoomTag] = []
    @State private var chapterSyncNote: String?
    @State private var playerRefresh = UUID()
    @State private var websiteVideoPlayer: AVPlayer?
    @State private var publishedVideoStatus: PublishedListingVideoStatus = .unpublished
    @State private var publishedVideoTask: Task<Void, Never>?
    @State private var showAerialIntro = false
    /// The toolbox's "Make a reel" tile presents Reel Studio DIRECTLY now.
    ///
    /// It used to be `NavigationLink { PhotoStudioView(listing:, intent: .reel) }`
    /// — the reel tile routed THROUGH the photo studio and relied on a "Make a
    /// reel" card at the bottom of that screen to finish the journey. That is
    /// the whole reason the reel card lived in AI Photo Studio, and it is why
    /// the owner's read after the 4,000 sq ft field test was that the photo
    /// studio "just opens the photo-to-reel feature". Reel Studio is its own
    /// screen; the tile goes there.
    @State private var showReelStudio = false
    @State private var showEdit = false
    @State private var showListingFactsReview = false
    @State private var showDeleteConfirm = false
    @State private var isDeleting = false
    /// Which of the two links a QR sheet is being shown for (nil = none).
    @State private var qrTarget: QRTarget?
    @State private var linkShareTarget: PublicLinkShareTarget?
    @State private var verifiedBuyerLink: (key: String, url: URL)?
    @State private var resolvingBuyerLinkKey: String?
    @StateObject private var connection = FeatureSessionAction()
    @State private var isPublishing = false
    @State private var publishFailure: AIFailure?
    /// "Republish tour" (build 58): pushes this phone's facts, photos and video
    /// to the live page without changing the link.
    @State private var isRepublishing = false
    @State private var republishFailure: AIFailure?
    @State private var republishedAt: Date?
    @ObservedObject private var publishUploads = UploadManager.shared
    /// "List this tour on Google". Seeded in `onAppear` from this listing's own
    /// answer, or from the workspace default when it has never been asked.
    @State private var listOnGoogle = false
    @State private var listOnGoogleSeeded = false

    // MARK: Compliance (W2-C2) — the org's AI provenance rows for THIS listing
    @State private var provenance: [ProvenanceRecord] = []
    @State private var provenanceCanExport: (() -> Bool)?
    @State private var isLoadingProvenance = false
    @State private var provenanceError: String?
    @State private var isExportingAudit = false
    @State private var auditExport: AuditExport?
    @State private var complianceNote: String?
    @State private var isSavingOriginals = false
    @State private var showComplianceDetails = false

    // MARK: Files (the 4,000 sq ft field test)
    /// Every file this listing has produced, read off disk on appear. NOT computed
    /// inside `body`: a directory scan per re-render is exactly what
    /// `PhotoStudioView.loadExisting()` avoids by loading into state once.
    @State private var mediaItems: [ListingMediaItem] = []
    /// Checked off the main thread, never by repeated filesystem reads in body.
    @State private var availableRerenderSource: URL?
    /// The file being viewed. ONE binding for every kind — `ListingFileViewer`
    /// switches internally — so `body` grows a single presentation modifier.
    @State private var openedFile: ListingMediaItem?
    @State private var filePhotoExport: PhotoExportSelection?
    @State private var filePhotoExportAdmission: (() -> Bool)?
    /// Build 60 "Share everything": the videos, scan and details note that
    /// ride along with the photos in the export sheet. Empty for photos only.
    @State private var filePackageExtras: [PhotoExportRenderer.Extra] = []
    @State private var packageError: String?
    /// Result of a Save-to-Photos from the files list (success or the reason it
    /// failed), shown under the section rather than in an alert. `filesNoteOK`
    /// only decides the icon and the colour — a green tick reads as done from
    /// across a room in a way that a grey sentence never did.
    @State private var filesNote: String?
    @State private var filesNoteOK = true
    @State private var isSavingFile = false
    /// Which files have gone to Photos during THIS visit to the screen, so their
    /// button can say "Saved" instead of inviting a second copy.
    ///
    /// Deliberately NOT persisted and deliberately not a claim about the library:
    /// the user can delete a photo in Photos, and an app that remembered "Saved"
    /// across launches would be lying about somebody else's camera roll. Within
    /// one visit it is exactly true, and that is the moment it is needed.
    @State private var savedFiles: Set<String> = []
    /// What the last scan saw, so an appearance that changed nothing does no
    /// work at all (the build-9 lag report — `onAppear` fires on every push AND
    /// every pop back, and walking into a studio and straight out again used to
    /// re-read every directory this listing owns).
    @State private var filesStamp: ListingMediaItem.ScanStamp?
    /// The scan in flight. Held so a fast push/pop can't land two results out
    /// of order: the next `loadFiles` cancels the previous one, and a cancelled
    /// scan drops its result rather than overwriting a newer list.
    @State private var filesTask: Task<Void, Never>?

    /// Retained for the life of the screen — a temporary CLGeocoder is released
    /// before its callback fires (F-A-26).
    @State private var geocoder = CLGeocoder()
    @State private var geocodeAttempted = false

    /// Live copy from the model (listing here is a value snapshot).
    private var currentListing: Listing {
        model.listings.first(where: { $0.id == listing.id }) ?? listing
    }

    private var hasCurrentPresentationContext: Bool {
        presentationScope.matches(actorID: auth.userID, orgID: WorkspaceContext.selectedOrgID)
    }

    /// Clear only this screen's presentation. Shared admitted jobs and their
    /// account/workspace completion fences continue to own background work.
    private func invalidatePresentation() {
        websiteVideoPlayer?.pause(); websiteVideoPlayer = nil
        publishedVideoTask?.cancel(); publishedVideoTask = nil
        publishedVideoStatus = .unpublished
        filesTask?.cancel(); filesTask = nil; filesStamp = nil
        mediaItems = []; availableRerenderSource = nil; openedFile = nil
        filePhotoExport = nil; filePhotoExportAdmission = nil; filePackageExtras = []; packageError = nil
        provenance = []; provenanceCanExport = nil; auditExport = nil
        showComplianceDetails = false
        showPhotosScreen = false; showRoomTagger = false; showReelStudio = false
        showRoomTagsWalkthroughHelp = false; showWalkthroughForRoomTags = false; availableRoomTagAsset = nil
        showAerialIntro = false; showEdit = false; showListingFactsReview = false
        qrTarget = nil
        linkShareTarget = nil; verifiedBuyerLink = nil; resolvingBuyerLinkKey = nil
        connection.cancel()
        dismiss()
    }

    /// The business type this screen speaks in. Samples carry no spaceTypeRaw
    /// (they are reseeded per type), so they follow the current selection.
    private var space: SpaceType {
        currentListing.isSample ? SpaceType.current : currentListing.spaceType
    }

    /// Two-way binding into the model's asset so the room tagger edits persist
    /// and the player refreshes.
    private var roomTagsBinding: Binding<[RoomTag]> {
        Binding(
            get: { self.roomTagAsset?.roomTags ?? [] },
            set: { newTags in
                if var a = self.roomTagAsset {
                    a.roomTags = newTags
                    self.model.assets[self.listing.id] = a
                }
            }
        )
    }

    // MARK: - router additions (auto room chapters)

    /// What the room tagger needs to ask the AI to name the rooms — nil unless
    /// this listing is really on the server, because the AI reads the video
    /// from OUR bucket, not from this phone.
    ///
    /// The only asset we hold a server id for is the RENDERED mp4
    /// (`uploadedRenderAssets`, written by `AppModel.publishTour`). Suggestions
    /// therefore come back on the RENDERED timeline, so the scale that takes
    /// them to the capture timeline `RoomTag.tMs` is written in is
    /// `speedFactor` — see `RoomTaggerView.captureMilliseconds`, which does the
    /// multiply and shows the arithmetic.
    ///
    /// The `relPath` check is the important one: `uploadedRenderAssets` records
    /// WHICH local file each server asset was uploaded from, and `publishTour`
    /// makes the same comparison before reusing an asset. Without it, a
    /// re-render (new tour, remembered id) would have the AI watch the OLD
    /// video and drop every room name at the wrong moment — the one failure
    /// this feature must not have.
    private var roomTagSuggestSource: RoomTagSuggestSource? {
        let l = currentListing
        guard !l.isSample, let serverID = l.serverID else { return nil }
        guard let tour, let remembered = model.uploadedRenderAssets[listing.id],
              remembered.relPath == FileStore.relativePath(for: tour.url),
              let assetID = UUID(uuidString: remembered.assetID) else { return nil }
        return RoomTagSuggestSource(api: model.api,
                                    listingServerID: serverID,
                                    assetID: assetID,
                                    assetSecondsToCaptureScale: safeSpeedFactor,
                                    isRenderAsset: true)
    }

    // MARK: - end router additions

    private var asset: CaptureAsset? { model.assets[listing.id] }
    private var tour: AppModel.RenderedTour? { model.tours[listing.id] }

    private var hasCurrentRoomTagContext: Bool {
        hasCurrentPresentationContext && model.listings.contains {
            $0.id == listing.id && !$0.isSample && $0.cloudUnavailable != true && model.isInSelectedWorkspace($0)
        }
    }

    private var roomTagGeneratedURLs: [URL] {
        [tour?.url, selectedWebsiteVideoURL, currentListing.aerialURL].compactMap { $0 }
    }

    /// Recheck on entry and tag writes; a cached tile cannot authorize a file
    /// that was deleted, replaced or moved to another account while open.
    private var roomTagAsset: CaptureAsset? {
        guard let asset, RoomTagWalkthroughPolicy.sourceURL(asset: asset, documents: FileStore.documents,
            isSample: currentListing.isSample, isCurrent: hasCurrentRoomTagContext,
            generatedURLs: roomTagGeneratedURLs) != nil else { return nil }
        return asset
    }

    private var canTagRooms: Bool {
        guard hasCurrentRoomTagContext, let asset, let checked = availableRoomTagAsset else { return false }
        return checked.id == asset.id && checked.localURL == asset.localURL
    }

    private func openRoomTags() {
        guard hasCurrentRoomTagContext else { return }
        guard let source = roomTagAsset else {
            availableRoomTagAsset = nil
            showRoomTagsWalkthroughHelp = true
            return
        }
        tagsBeforeEdit = source.roomTags
        showRoomTagger = true
    }

    private func openWalkthroughForRoomTags() {
        guard hasCurrentRoomTagContext else { return }
        showRoomTagsWalkthroughHelp = false
        showWalkthroughForRoomTags = true
    }

    private var mapCoordinate: CLLocationCoordinate2D? {
        let l = currentListing
        guard let lat = l.latitude, let lon = l.longitude,
              lat.isFinite, lon.isFinite else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    // Industry-specific detail fields the owner filled (non-real-estate).
    private var detailRowFields: [DetailField] {
        space.detailFields.filter { !$0.isURL && !currentListing.detail($0.key).isEmpty }
    }
    private var detailLinkFields: [DetailField] {
        space.detailFields.filter { $0.isURL && !currentListing.detail($0.key).isEmpty }
    }
    private func normalizedURL(_ raw: String) -> URL? {
        let t = raw.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        return URL(string: t.lowercased().hasPrefix("http") ? t : "https://\(t)")
    }
    private func linkLabel(_ f: DetailField) -> String {
        f.key == space.actionURLKey ? space.ctaTitle : f.label
    }

    /// Prefer the rendered tour; fall back to the raw capture.
    private var playbackURL: URL? { tour?.url ?? asset?.localURL }

    private var selectedWebsiteVideoURL: URL? {
        guard let selected = currentListing.websiteVideo, selected.listingID == listing.id,
              selected.ownerID == auth.userID, selected.workspaceID == WorkspaceContext.selectedOrgID,
              selected.serverListingID == currentListing.serverID,
              let url = try? ListingVideoStore.fileURL(selected, documents: FileStore.documents),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// A saved reel is a device file; the website's selected photo video comes
    /// from the public tour projection. Keep its answer separate from the local
    /// selection so a Studio publication cannot be mistaken for missing work.
    private func refreshPublishedVideo() {
        publishedVideoTask?.cancel()
        let live = currentListing, expectedScope = presentationScope
        guard hasCurrentPresentationContext, !live.isSample, live.serverID != nil,
              let slug = live.shareSlug, Config.useLiveBackend else {
            publishedVideoStatus = .unpublished
            return
        }
        guard let reader = model.api as? PublishedListingVideoReading else {
            publishedVideoStatus = .unavailable
            return
        }
        publishedVideoStatus = .checking
        publishedVideoTask = Task {
            do {
                let state = try await reader.publishedListingVideo(slug: slug)
                guard !Task.isCancelled, expectedScope == presentationScope,
                      hasCurrentPresentationContext, currentListing.serverID == live.serverID,
                      currentListing.shareSlug == slug else { return }
                publishedVideoStatus = state.listingVideo.map { .live($0.durationS) } ?? .noPhotoVideo
            } catch {
                guard !Task.isCancelled, expectedScope == presentationScope,
                      hasCurrentPresentationContext, currentListing.serverID == live.serverID,
                      currentListing.shareSlug == slug else { return }
                publishedVideoStatus = .unavailable
            }
        }
    }

    private var visiblePublishedVideoStatus: PublishedListingVideoStatus {
        guard !currentListing.isSample, Config.useLiveBackend,
              currentListing.shareSlug != nil else { return .unpublished }
        return publishedVideoStatus == .unpublished ? .checking : publishedVideoStatus
    }

    private var listingVideoCardContent: ListingVideoCardContent {
        visiblePublishedVideoStatus.card(hasLocalSelection: currentListing.websiteVideoRelPath != nil)
    }

    /// The tour's retime factor, sanitized: a 0/NaN factor would trap the
    /// integer conversions below (F-A-26), so anything degenerate reads as 1×.
    private var safeSpeedFactor: Double {
        guard let tour, tour.speedFactor.isFinite, tour.speedFactor > 0 else { return 1 }
        return tour.speedFactor
    }

    /// Room tags, rescaled when the tour was retimed (2× walk → ÷2 timestamps).
    /// Same rounding as `AppModel.publishTour` so the in-app dots and the hosted
    /// chapters agree to the millisecond.
    private var playbackTags: [RoomTag] {
        guard let asset else { return [] }
        guard tour != nil else { return asset.roomTags }
        let sf = safeSpeedFactor
        return asset.roomTags.map { tag in
            RoomTag(name: tag.name, tMs: Int((Double(tag.tMs) / sf).rounded()))
        }
    }

    /// The REAL hosted share link — exists only after publish. NEVER fabricate
    /// a /f/<uuid-prefix> URL: it has no server row and 404s for the recipient
    /// (2026-08-26 audit P0-2; PortfolioExporter enforces the same rule).
    /// Share actions below are gated on this being non-nil.
    private var shareURL: URL? {
        currentListing.serverShareURL
    }

    var body: some View {
        ScrollView {
            if hasCurrentPresentationContext {
            VStack(spacing: Theme.spacing) {
                if !currentListing.isSample {
                    Button { showEdit = true } label: {
                        Label("Manage listing details", systemImage: "pencil")
                            .font(.rpBody.weight(.semibold)).frame(maxWidth: .infinity, alignment: .leading)
                            .padding().background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: Theme.radius))
                    }.foregroundStyle(Theme.accent).accessibilityIdentifier("listing.editDetails")
                }
                if !currentListing.isSample && listingFactsNeedReview {
                    ListingFactsReviewCard { showListingFactsReview = true }
                }
                if let notice = model.cloudPhotoNotice(for: listing.id) {
                    Text(notice).font(.rpCaption).foregroundStyle(Theme.inkDim)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("listing.photoCoverPreserved")
                }
                toolboxSection
                if !currentListing.isSample {
                    NavigationLink { ProductionPlanView(listing: currentListing) } label: {
                        nextStepHeader("checklist", "Plan recorded shots", "Keep a shot checklist for this property before recording.")
                            .padding(14).background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(ScalePressStyle())
                    .accessibilityIdentifier("listing.productionPlan")
                }
                tourSection
                if let smoothing = tour?.motionSmoothing {
                    Text(smoothing == "unavailable"
                         ? "Motion smoothing wasn't available for this footage. Preview the video before sharing."
                         : smoothing == "applied"
                         ? "Camera-shake correction applied. Preview the video to check walking movement and framing."
                         : "The video had little measured shake. Preview the movement before sharing.")
                        .font(.rpCaption).foregroundStyle(Theme.inkDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !currentListing.isSample { ListingClientContactSummary(listing: currentListing) }
                if !currentListing.isSample {
                    NavigationLink { WebsiteDesignPickerView(listing: currentListing) } label: {
                        nextStepHeader("rectangle.3.group", "Website design", "Choose the look of this property's website.")
                            .padding(14).background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
                    }.buttonStyle(ScalePressStyle()).accessibilityIdentifier("listing.websiteDesign")
                }
                if let shareURL {
                    shareSection(shareURL)
                } else {
                    nextStepCard
                }
                filesSection
                performanceSection
                infoSection
                detailsSection
                mapSection
                searchIndexingCard
                if !currentListing.isSample, currentListing.serverID != nil {
                    NavigationLink { CloudMediaView(listing: currentListing) } label: {
                        Label("Cloud files from Studio & iPhone", systemImage: "icloud.and.arrow.down")
                            .font(.rpBody.weight(.semibold)).frame(maxWidth: .infinity).padding(16)
                            .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 14))
                    }
                }
                complianceSection
                if !currentListing.isSample {
                    manageSection
                    DesktopStudioCard().padding(16)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius))
                }
            }
            .padding()
            .askAI(.listing, listingID: listing.id)
            } else {
                Text("Your account or workspace changed. Reopen the listing from your current workspace.")
                    .font(.rpBody).foregroundStyle(Theme.inkDim).padding()
            }
        }
        .background(Theme.bg)
        .navigationTitle(hasCurrentPresentationContext ? currentListing.address : "Listing")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refreshClientContactIfCurrent() }
        .disabled(!hasCurrentPresentationContext || isDeleting || connection.isWaiting)
        .sessionConnectionNotice(isActive: connection.isWaiting, onCancel: { connection.cancel() })
        .onDisappear {
            connection.cancel(); filesTask?.cancel(); filesTask = nil
            publishedVideoTask?.cancel(); publishedVideoTask = nil
        }
        .onAppear {
            guard hasCurrentPresentationContext else { invalidatePresentation(); return }
            // Seed the Zillow field ONCE — re-seeding on every appearance wiped
            // an in-progress paste when a sheet closed (F-A-26).
            if !zillowSeeded {
                zillowText = currentListing.zillowURL ?? ""
                zillowSeeded = true
            }
            // Same once-only rule: this listing's own answer if it has one,
            // otherwise the workspace default (which is OFF until somebody
            // says otherwise).
            if !listOnGoogleSeeded {
                listOnGoogle = currentListing.allowSearchIndexing ?? false
                listOnGoogleSeeded = true
            }
            // Photos-first: push the photo library the moment this screen
            // appears, exactly once. `didAutoOpenPhotos` is what stops the pop
            // back from re-pushing it and trapping the user in a loop.
            if openPhotosOnAppear && !didAutoOpenPhotos && !currentListing.isSample {
                didAutoOpenPhotos = true
                showPhotosScreen = true
            }
            geocodeIfNeeded()
            // Still called on every appearance — coming back from AI Photo
            // Studio, Reel Studio or the floor-plan scanner is a push/pop, so
            // this is where a file made in one of them first becomes visible
            // here. It is no longer a directory sweep on the main thread: see
            // `loadFiles`, which checks five modification dates on a background
            // thread and does nothing at all when none of them moved.
            loadFiles()
            refreshPublishedVideo()
        }
        .navigationDestination(isPresented: $showPhotosScreen) {
            // Keep the large photo editor out of this listing's concrete
            // NavigationLink type. iOS 18 feedback crashed resolving that
            // eager destination's generic metadata before Photos could open.
            AnyView(PhotoStudioView(listing: currentListing, entry: .photos))
        }
        .navigationDestination(isPresented: $showWalkthroughForRoomTags) {
            if hasCurrentRoomTagContext { RecordedWalkthroughView(listing: currentListing) }
        }
        .alert("Add a walkthrough first", isPresented: $showRoomTagsWalkthroughHelp) {
            Button("Open walkthrough") { openWalkthroughForRoomTags() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Record or upload a drone-style walkthrough before tagging rooms or areas. Tags follow that video's timeline. A photo-based listing video or sample tour doesn't add walkthrough footage.")
        }
        .fullScreenCover(item: $openedFile, onDismiss: { loadFiles(force: true) }) { item in
            ListingFileViewer(item: item, listingID: listing.id,
                              canExport: mediaExportAdmission(for: currentListing))
        }
        .alert("Couldn't prepare the listing package", isPresented: Binding(get: { packageError != nil }, set: { if !$0 { packageError = nil } })) {
            Button("OK", role: .cancel) { packageError = nil }
        } message: {
            Text(packageError ?? "")
        }
        .sheet(item: $filePhotoExport, onDismiss: { filePackageExtras = [] }) { selection in
            // Build 58: originals ride along by default (the toggle stays) — a
            // download should carry the AI disclosure AND the unaltered source.
            // Build 60: "Share everything" adds the videos and a details note.
            PhotoExportSheet(photos: selection.photos, includeOriginals: true,
                             archiveName: currentListing.address, extras: filePackageExtras,
                             coordinatorPackage: !filePackageExtras.isEmpty,
                             canExport: filePhotoExportAdmission ?? { false },
                             onExported: PhotoFeedbackQueue.recordExport)
        }
        .onChange(of: auth.userID) { _ in
            if !hasCurrentPresentationContext { invalidatePresentation() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .rendpropWorkspaceChanged)) { _ in
            if !hasCurrentPresentationContext { invalidatePresentation() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            if hasCurrentPresentationContext { refreshPublishedVideo() }
        }
        .onChange(of: currentListing.shareSlug) { _ in
            if hasCurrentPresentationContext { refreshPublishedVideo() }
        }
        // "Make a reel" opens REEL STUDIO, with this listing's photos and its
        // aerial intro — the same two things `PhotoStudioView` used to hand it
        // one screen further along.
        //
        // `extraClipURLs` is the aerial-as-intro fix and MUST NOT regress: the
        // path most people take is this tile, and before that fix the aerial
        // could only be used as a reel intro from inside the aerial sheet.
        // `photos:` is read at presentation time (a fullScreenCover builds its
        // content when it is presented), so a photo added since this screen
        // appeared is included — the same live read `PhotoStudioView` did with
        // its own `photos` state.
        //
        // `force: true` on dismiss for the same reason the aerial sheet uses it:
        // a finished reel is a new file in this listing's folder, written while
        // this screen stayed put, so the FILES scan cannot trust its stamp.
        .fullScreenCover(isPresented: $showReelStudio, onDismiss: { loadFiles(force: true) }) {
            ReelStudioView(listing: currentListing,
                           photos: (try? EnhancedPhoto.loadForListing(listingID: currentListing.id)) ?? [],
                           extraClipURLs: currentListing.aerialURL.map { [$0] } ?? [])
                .environmentObject(model)
        }
        .task { await loadCompliance() }
        .task(id: asset?.localURL) {
            availableRerenderSource = nil
            let expectedScope = presentationScope
            guard hasCurrentPresentationContext else { return }
            guard let source = asset?.localURL, source.isFileURL else { return }
            let exists = await Task.detached(priority: .utility) {
                FileManager.default.fileExists(atPath: source.path)
            }.value
            guard !Task.isCancelled, exists, expectedScope == presentationScope,
                  hasCurrentPresentationContext, asset?.localURL == source else { return }
            availableRerenderSource = source
        }
        .task(id: asset) {
            availableRoomTagAsset = nil
            let expectedScope = presentationScope
            guard hasCurrentRoomTagContext, let source = asset else { return }
            let documents = FileStore.documents, generated = roomTagGeneratedURLs
            let url = await Task.detached(priority: .utility) {
                RoomTagWalkthroughPolicy.sourceURL(asset: source, documents: documents,
                    isSample: false, isCurrent: true, generatedURLs: generated)
            }.value
            guard !Task.isCancelled, url != nil, expectedScope == presentationScope,
                  hasCurrentRoomTagContext, asset == source else { return }
            availableRoomTagAsset = source
        }
        .onChange(of: spaceTypeRaw) { _ in
            // The list this screen was opened from no longer contains this
            // listing — go back rather than showing another industry's detail.
            if !currentListing.belongsToCurrentType { dismiss() }
        }
        .sheet(isPresented: $showRoomTagger, onDismiss: roomTaggerDismissed) {
            if let a = roomTagAsset {
                RoomTaggerView(videoURL: a.localURL, tags: roomTagsBinding,
                               suggest: roomTagSuggestSource, listingID: listing.id)
            }
        }
        // `force`: this is the one presentation that can have written a file
        // while the listing screen stayed put, so it skips the stamp check
        // rather than trusting a directory date written a moment ago. It can
        // produce TWO kinds — the flyover itself, and a reel from the Reel
        // Studio cover it presents — so a targeted "reload the aerial" would be
        // wrong here.
        .sheet(isPresented: $showAerialIntro, onDismiss: { loadFiles(force: true) }) {
            AerialIntroSheet(listing: currentListing)
                .environmentObject(model)
        }
        .sheet(isPresented: $showEdit) {
            ListingEditSheet(listing: currentListing)
                .environmentObject(model)
        }
        .sheet(isPresented: $showListingFactsReview) {
            ListingFactsReviewSheet(listingID: listing.id)
        }
        .sheet(item: $qrTarget) { target in
            QRShareSheet(url: target.url, title: currentListing.address,
                         linkName: target.linkName, caption: target.caption)
        }
        .sheet(item: $linkShareTarget) { target in
            ShareSheet(items: target.activityItems)
        }
        .sheet(item: $auditExport) { export in
            ShareSheet(items: [export.url])
        }
        .confirmationDialog("Delete this \(space.spaceNoun)?", isPresented: $showDeleteConfirm,
                            titleVisibility: .visible) {
            Button("Delete \(space.spaceNoun)", role: .destructive) { deleteListing() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteMessage)
        }
    }

    // MARK: - Sections

    private var speedLabel: String {
        guard tour != nil else { return "" }
        return String(format: "%.3g", safeSpeedFactor)   // 1.25× prints as "1.25", not "1.2"
    }

    private var tourCaption: String {
        if tour != nil {
            return "Scroll inside to fly through — rendered at \(speedLabel)× glide speed, 60fps, instant scrubbing."
        }
        if asset != nil {
            return "Scroll inside to fly through your walkthrough. Create the tour below to render the glide."
        }
        if currentListing.isSample {
            return "Sample tour — create your own \(space.spaceNoun) to see it here."
        }
        return "No video yet — add a walkthrough below and this becomes your tour."
    }

    private var listingVideoCaption: String {
        if currentListing.isSample { return tourCaption }
        switch visiblePublishedVideoStatus {
        case .live:
            return "Selected on this listing's live website. Your recorded walkthrough and saved phone videos stay separate."
        case .checking:
            return "Checking the live website's selected video. Your saved videos are listed below."
        case .unavailable:
            return "The live website couldn't be checked. Open its link to see the current video; your saved files are below."
        case .noPhotoVideo, .unpublished:
            return currentListing.websiteVideoRelPath != nil
                ? "Saved on this phone and ready to publish on the listing website. Your recorded walkthrough stays separate."
                : "A photo-based listing video is the main presentation. Open Drone-style walkthrough for recorded footage."
        }
    }

    private var tourSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(currentListing.isSample ? "SAMPLE TOUR" : "LISTING VIDEO")
                .font(.rpKicker).foregroundStyle(Theme.inkDim)
            Group {
                if case .live(let duration) = listingVideoCardContent {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Listing video is live", systemImage: "checkmark.circle.fill")
                            .font(.rpHeadline).foregroundStyle(Theme.good)
                            .accessibilityIdentifier("listing.videoLive")
                        Text("Your \(duration.formatted(.number.precision(.fractionLength(0...1))))-second photo video is selected on this property's website.")
                            .font(.rpBody).foregroundStyle(Theme.ink)
                        if let page = currentListing.serverShareURL {
                            Link(destination: page) {
                                Label("Watch on property website", systemImage: "play.rectangle")
                                    .font(.rpBody.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                                    .modifier(RendpropActionLabelSurface(primary: true))
                            }
                        }
                    }.padding()
                } else if listingVideoCardContent == .local {
                    if let selectedWebsiteVideoURL {
                        VideoPlayer(player: websiteVideoPlayer)
                            .aspectRatio(16.0 / 9.0, contentMode: .fit)
                            .task(id: currentListing.websiteVideo?.id) {
                                websiteVideoPlayer?.pause()
                                guard hasCurrentPresentationContext else { return }
                                websiteVideoPlayer = AVPlayer(url: selectedWebsiteVideoURL)
                            }
                            .onDisappear { websiteVideoPlayer?.pause() }
                    } else {
                        Text("This saved selection isn't available on this phone. Open Make a video to choose another saved file.")
                            .font(.rpBody).foregroundStyle(Theme.inkDim).padding()
                    }
                } else if listingVideoCardContent == .checking {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Checking the listing website…")
                            .font(.rpBody).foregroundStyle(Theme.inkDim)
                            .accessibilityIdentifier("listing.videoChecking")
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if listingVideoCardContent == .unavailable {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Website video status unavailable", systemImage: "wifi.exclamationmark")
                            .font(.rpHeadline).foregroundStyle(Theme.ink)
                            .accessibilityIdentifier("listing.videoUnavailable")
                        Text("Open the live website to check its selected video. Your saved videos are listed below.")
                            .font(.rpBody).foregroundStyle(Theme.inkDim)
                        if let page = currentListing.serverShareURL {
                            Link("Open property website", destination: page)
                                .font(.rpBody.weight(.semibold))
                        }
                    }.padding()
                } else if !currentListing.isSample {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Your property video starts with photos", systemImage: "photo.on.rectangle")
                            .font(.rpHeadline).foregroundStyle(Theme.ink)
                        Text("Add and polish property photos, then choose Listing in Make a video. Your landscape video becomes this listing's presentation; a recorded walkthrough is an optional separate tool.")
                            .font(.rpBody).foregroundStyle(Theme.inkDim)
                        PrimaryButton(title: "Make a listing video", systemImage: "film.stack") {
                            showReelStudio = true
                        }
                        .accessibilityIdentifier("listing.primaryVideoStart")
                    }.padding()
                } else if currentListing.isSample, space != .realEstate, !PlayerWebView.bundledDemoAvailable,
                   let demo = PlayerWebView.hostedDemoEmbedURL(for: space) {
                    // A build WITHOUT player/demo.mp4: a venue's / bar's / gym's
                    // sample plays the hosted demo flythrough presented as a
                    // sample tour — "Sample video unavailable" is not a first
                    // impression (industry review P1-6). With the clip in the
                    // build (every archive from the Mac), the bundled player
                    // below carries the sample's own name, tagline, chapters
                    // and identity — never the demo home's price.
                    PlayerWebView(remoteURL: demo)
                } else {
                    PlayerWebView(localVideoURL: playbackURL, roomTags: playbackTags, listing: currentListing)
                }
            }
                .id(playerRefresh)
                .frame(height: currentListing.isSample ? 460 : 230)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                        .strokeBorder(Theme.border)
                )
            Text(listingVideoCaption)
                .font(.rpCaption)
                .foregroundStyle(Theme.inkDim)
        }
    }

    /// Share actions — only once the REAL hosted link exists. Before publish
    /// there is nothing at any URL, so sharing would send a dead 404 link.
    ///
    /// TWO links, never one, ON REAL ESTATE (W2-C1). The branded `/f/` page
    /// carries the agent card, the CTA and the lead form; unbranded virtual-tour
    /// rules ban all three, and the unbranded field is the one that syndicates
    /// to Zillow/Realtor.com. Pasting the branded link into an MLS unbranded
    /// field is a fineable offence (RI Statewide MLS: $50 for a first
    /// branded-photo violation, escalating from there), so the MLS link is
    /// labelled loudly and carries the warning underneath it. Every other
    /// business type has no MLS and gets the one shareable link —
    /// `Listing.serverUnbrandedURL` is nil off real estate (industry review
    /// P1-2).
    private func shareSection(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SHARE").font(.rpKicker).foregroundStyle(Theme.inkDim)

            linkCard(
                url: DeepLink.buyerWebsiteURL(from: url, address: currentListing.spaceType == .realEstate ? currentListing.address : nil) ?? url,
                verifyBrandedLink: true,
                icon: "person.text.rectangle.fill",
                tint: Theme.accent,
                name: "Your link",
                blurb: "\(space.profileCardName) + lead capture. Email, social, texts, QR.",
                shareSubject: currentListing.address,
                shareMessage: "See photos and the property video for \(currentListing.address).",
                shareTitle: "Share your link",
                qrCaption: space == .realEstate
                    ? "Scan to open your property website — flyers, sign riders, open-house sheets."
                    : "Scan to open your property website — flyers, counter cards, the front window.")

            if let mls = currentListing.serverUnbrandedURL {
                linkCard(
                    url: DeepLink.unbrandedWebsiteURL(from: mls, address: currentListing.address) ?? mls,
                    icon: "building.columns.fill",
                    tint: Theme.good,
                    name: "MLS link — unbranded",
                    blurb: "Unbranded. Safe for the MLS virtual-tour field.",
                    shareSubject: "Unbranded tour — \(currentListing.address)",
                    shareMessage: "Unbranded virtual tour for \(currentListing.address).",
                    shareTitle: "Share MLS link",
                    qrCaption: "Unbranded: the property and nothing else — no agent card, no contact form.",
                    warning: "Never put your branded link in an MLS unbranded field — most MLSs fine for that.")
            }

            if let chapterSyncNote {
                Text(chapterSyncNote)
                    .font(.rpCaption)
                    .foregroundStyle(Theme.inkDim)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            republishCard
        }
    }

    /// Build 58. Facts and photos already reach the page as they sync, but an
    /// agent who just changed something wants to SEE it go live, and a re-shot
    /// walkthrough has to be pushed on purpose. One button does all of it and
    /// keeps the link: the server moves the tour in place (republish_render).
    private var republishExplanation: String {
        if currentListing.websiteVideoRelPath != nil {
            return "Republish sends this phone's selected video, details and photos. If another video is live from Studio, this may replace it. Your links stay the same."
        }
        if case .live = visiblePublishedVideoStatus {
            return "Republish sends this phone's latest details, photos and optional recorded walkthrough. The selected photo video stays on your website. Your links stay the same."
        }
        return "Republish sends this phone's latest details, photos and walkthrough to the live page. Your links stay the same — flyers, QR codes and the MLS field keep working."
    }

    private var republishCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Made changes?")
                        .font(.rpHeadline)
                        .foregroundStyle(Theme.ink)
                    Text(republishExplanation)
                        .font(.rpCaption)
                        .foregroundStyle(Theme.inkDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            if let failure = republishFailure,
               tour != nil || currentListing.websiteVideoRelPath != nil {
                AIFailureCard(failure: failure,
                              retryHint: "Tap Republish tour to try again.",
                              quotaFeature: "renders",
                              onReconnect: { republishNow() })
            }
            if tour == nil && currentListing.websiteVideoRelPath == nil {
                Text("Your details and photos sync automatically. Make a new video or add a walkthrough here before republishing from this phone.")
                    .font(.rpCaption).foregroundStyle(Theme.inkDim)
            } else if isRepublishing {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(tour == nil
                         ? "Republishing — sending your latest details and photos."
                         : "Republishing — sending your latest details, photos and walkthrough. Keep the app open.")
                        .font(.rpCaption).foregroundStyle(Theme.inkDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
                .accessibilityIdentifier("detail.republishing")
            } else {
                Button { republishNow() } label: {
                    Label(republishFailure == nil ? "Republish tour" : "Retry republish", systemImage: "arrow.triangle.2.circlepath")
                        .font(.rpBody.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .modifier(RendpropActionLabelSurface(primary: false))
                }
                .buttonStyle(ScalePressStyle())
                .disabled(!model.isInSelectedWorkspace(currentListing) || currentListing.cloudUnavailable == true || isPublishing)
                .accessibilityIdentifier("detail.republish")
            }
            if let stamp = republishedAt ?? currentListing.lastRepublishedAt {
                Label("Live page updated \(Self.republishStamp.localizedString(for: stamp, relativeTo: Date()))", systemImage: "checkmark.circle.fill")
                    .font(.rpCaption)
                    .foregroundStyle(Theme.good)
                    .accessibilityIdentifier("detail.republished")
            }
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
    private static let republishStamp = RelativeDateTimeFormatter()

    /// One labelled link: what it is, the URL itself, Copy / QR, and Share.
    /// `warning` renders the MLS one-liner under the row.
    private func linkCard(url: URL, verifyBrandedLink: Bool = false, icon: String, tint: Color, name: String, blurb: String,
                          shareSubject: String, shareMessage: String, shareTitle: String,
                          qrCaption: String, warning: String? = nil) -> some View {
        let published = currentListing.serverShareURL
        let linkKey = shareLinkKey(for: url, listing: currentListing)
        let displayURL = verifyBrandedLink && verifiedBuyerLink?.key == linkKey
            ? verifiedBuyerLink?.url ?? url : url
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.rpHeadline)
                        .foregroundStyle(Theme.ink)
                    Text(blurb)
                        .font(.rpCaption)
                        .foregroundStyle(Theme.inkDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            Text(displayURL.absoluteString)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Theme.inkDim)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(Theme.fillSubtle, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            HStack(spacing: 10) {
                Button {
                    guard let target = actionLink(url, key: linkKey,
                                                  verifyBrandedLink: verifyBrandedLink) else { return }
                    UIPasteboard.general.url = target
                    Haptics.success()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .accessibilityLabel(Text("Copy \(name)"))
                Button {
                    guard let target = actionLink(url, key: linkKey,
                                                  verifyBrandedLink: verifyBrandedLink) else { return }
                    qrTarget = QRTarget(url: target, linkName: name, caption: qrCaption)
                } label: {
                    Label("QR", systemImage: "qrcode")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .accessibilityLabel(Text("QR code for \(name)"))
            }
            .font(.rpBody)

            Button {
                guard let target = actionLink(url, key: linkKey,
                                              verifyBrandedLink: verifyBrandedLink) else { return }
                linkShareTarget = PublicLinkShareTarget(
                    url: target,
                    subject: shareSubject, message: shareMessage)
            } label: {
                Label(shareTitle, systemImage: "square.and.arrow.up")
                    .font(.rpBody.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(tint)
                    .foregroundStyle(Color.white)
                    .clipShape(Capsule())
            }

            if verifyBrandedLink && resolvingBuyerLinkKey == linkKey {
                ProgressView("Checking address link")
                    .font(.rpCaption)
                    .foregroundStyle(Theme.inkDim)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.rpCaption.weight(.semibold))
                    .foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .task(id: linkKey) {
            guard verifyBrandedLink, let published,
                  canShareLink(url, key: linkKey, verifyBrandedLink: true) else { return }
            resolvingBuyerLinkKey = linkKey
            let resolved = await PublicShareLinkResolver.resolve(publishedURL: published, fallbackURL: url)
            guard !Task.isCancelled,
                  canShareLink(url, key: linkKey, verifyBrandedLink: true) else {
                if resolvingBuyerLinkKey == linkKey { resolvingBuyerLinkKey = nil }
                return
            }
            verifiedBuyerLink = (linkKey, resolved)
            resolvingBuyerLinkKey = nil
        }
    }

    private func actionLink(_ fallback: URL, key: String, verifyBrandedLink: Bool) -> URL? {
        PublicShareLinkResolver.linkForAction(
            fallbackURL: fallback, linkKey: key,
            currentContext: canShareLink(fallback, key: key, verifyBrandedLink: verifyBrandedLink),
            cached: verifyBrandedLink ? verifiedBuyerLink : nil)
    }

    private func shareLinkKey(for fallback: URL, listing current: Listing) -> String {
        "\(current.id):\(fallback.absoluteString):\(current.serverShareURL?.absoluteString ?? ""):\(current.address):\(current.allowSearchIndexing == true)"
    }

    private func canShareLink(_ fallback: URL, key: String, verifyBrandedLink: Bool) -> Bool {
        guard hasCurrentPresentationContext,
              let current = model.listings.first(where: { $0.id == listing.id }),
              current.cloudUnavailable != true, model.isInSelectedWorkspace(current) else { return false }
        if verifyBrandedLink {
            guard let published = current.serverShareURL else { return false }
            let currentFallback = DeepLink.buyerWebsiteURL(
                from: published, address: current.spaceType == .realEstate ? current.address : nil) ?? published
            return currentFallback == fallback && key == shareLinkKey(for: fallback, listing: current)
        }
        guard let published = current.serverUnbrandedURL else { return false }
        let currentFallback = DeepLink.unbrandedWebsiteURL(from: published, address: current.address) ?? published
        return currentFallback == fallback && key == shareLinkKey(for: fallback, listing: current)
    }

    // MARK: - "List this tour on Google"
    //
    // THE DEFECT this fixes. A hosted tour is `noindex, nofollow` until its
    // owner opts that listing in, and that default is correct — the page
    // carries their name, phone, e-mail and a street address, and putting that
    // in a permanent public index is their call, not ours. But the opt-in
    // existed ONLY as a key inside the listing's freeform `details` bag, which
    // no screen has ever written and no agent could ever find. The structured
    // data the tour host emits is gated on the same flag, so it did nothing for
    // anybody either.
    //
    // So the question gets asked, once, in plain words, where the decision
    // actually happens: on the publish/share screen, next to the button that
    // makes the page public. Default OFF. "Not now" costs nothing: the link
    // works identically either way — the only thing this changes is whether a
    // stranger can arrive at it through a search box.

    @ViewBuilder private var searchIndexingCard: some View {
        if !currentListing.isSample, tour != nil || currentListing.websiteVideoRelPath != nil || shareURL != nil {
            VStack(alignment: .leading, spacing: 10) {
                Text("SEARCH").font(.rpKicker).foregroundStyle(Theme.inkDim)
                Toggle(isOn: Binding(get: { listOnGoogle },
                                     set: { setListOnGoogle($0) })) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Allow this published property to appear in search engines")
                            .font(.rpBody.weight(.semibold))
                            .foregroundStyle(Theme.ink)
                        Text("Turning this on lets search engines show this page, which makes the address and your \(space.profileCardName.lowercased()) — your name, phone and email — findable by anyone searching. Your leads, your files and your other tours stay private either way, and your link keeps working whether it's on or off.")
                            .font(.rpCaption)
                            .foregroundStyle(Theme.inkDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(Theme.accent)
                .accessibilityIdentifier("listing.listOnGoogle")
                Text(shareURL == nil
                     ? "Off unless you choose it for this property. Your shared link works either way."
                     : "Changing this updates the search preference for this property. Search engines decide when to index it.")
                    .font(.rpCaption)
                    .foregroundStyle(Theme.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
    }

    /// The answer, written three places: this screen's state, the listing (which
    /// is what actually reaches the server), and the workspace default for the
    /// next tour. A live page is PATCHed straight away rather than waiting for
    /// the next publish — the page is already out there.
    private func setListOnGoogle(_ allowed: Bool) {
        listOnGoogle = allowed
        SearchIndexingDefault.remember(allowed)
        guard !currentListing.isSample else { return }
        model.setSearchIndexing(allowed, for: listing.id)
        Haptics.selection()
        if currentListing.serverID != nil {
            // Never throws, never blocks the UI: a failure leaves the listing
            // dirty and the next sync carries it.
            Task { await model.syncListing(listing.id) }
        }
    }

    /// The honest next step for a listing that has no share link yet — a real
    /// action, never a passive "publish to get your link" banner (F-A-08):
    /// rendered tour → Publish; video but no tour → Create tour; nothing → Add
    /// a walkthrough; sample → create your own.
    @ViewBuilder private var nextStepCard: some View {
        if currentListing.isSample {
            sampleCard
        } else if tour != nil || currentListing.websiteVideoRelPath != nil {
            publishCard
        } else {
            startListingVideoCard
        }
    }

    private var startListingVideoCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            nextStepHeader("photo.on.rectangle", "Build your listing presentation",
                "Add property photos, polish the ones you want, then make a landscape Listing video. Review it and choose Use on listing website before publishing.")
            lastErrorBanner
            Button { showPhotosScreen = true } label: {
                nextStepLabel("Add or review photos", "photo.stack")
            }.buttonStyle(ScalePressStyle()).accessibilityIdentifier("listing.startPhotos")
            Button { showReelStudio = true } label: {
                Label("Make a listing video", systemImage: "film.stack")
                    .font(.rpBody.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(Theme.card).foregroundStyle(Theme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }.buttonStyle(ScalePressStyle()).accessibilityIdentifier("listing.startVideo")
            Text("Recording or uploading a drone-style walkthrough is optional. Its separate tool is in the toolbox.")
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
        }.padding(14).background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder private var lastErrorBanner: some View {
        if let err = currentListing.lastError?.trimmingCharacters(in: .whitespacesAndNewlines), !err.isEmpty {
            Label(err, systemImage: "exclamationmark.triangle.fill")
                .font(.rpCaption.weight(.semibold))
                .foregroundStyle(Theme.warn)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func nextStepHeader(_ icon: String, _ title: String, _ sub: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.rpHeadline).foregroundStyle(Theme.ink)
                Text(sub)
                    .font(.rpCaption).foregroundStyle(Theme.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func nextStepLabel(_ title: String, _ icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.rpBody.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .modifier(RendpropActionLabelSurface(primary: true))
    }

    private var publishCellularParked: Bool {
        guard publishUploads.pendingCellularConfirmation,
              let upload = publishUploads.state, upload.status == .queued,
              upload.role == "render", upload.listingID == currentListing.serverID,
              upload.listingLocalID == nil || upload.listingLocalID == listing.id,
              upload.filePath == (currentListing.websiteVideo?.relativePath ?? tour.map { FileStore.relativePath(for: $0.url) }),
              model.isInSelectedWorkspace(currentListing), currentListing.cloudUnavailable != true else { return false }
        return true
    }

    private var hasPublishProblem: Bool {
        publishFailure != nil || !(currentListing.lastError ?? "").isEmpty
    }

    private var publishCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            nextStepHeader("link.badge.plus", "Publish to get your share link",
                           "Your tour is rendered on this phone. Publishing puts it on a live rendprop.com page you can send to \(space.customerNoun) — no re-render.")
            lastErrorBanner
            if let failure = publishFailure {
                AIFailureCard(failure: failure,
                              retryHint: "Tap Publish tour to try again.",
                              quotaFeature: "renders",
                              onReconnect: { publishNow() })
            }
            if isPublishing {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Publishing — uploading the rendered video. Keep the app open.")
                        .font(.rpCaption).foregroundStyle(Theme.inkDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            } else if publishCellularParked {
                Text("Your video is saved. Publishing will continue on Wi-Fi, or you can approve this upload on cellular.")
                    .font(.rpCaption).foregroundStyle(Theme.inkDim)
                Button { publishNow(cellularApproved: true) } label: {
                    nextStepLabel("Upload now on cellular", "antenna.radiowaves.left.and.right")
                }.buttonStyle(ScalePressStyle())
                    .accessibilityIdentifier("phase1.publishCellular")
            } else {
                Button { publishNow() } label: {
                    nextStepLabel(hasPublishProblem ? "Retry publish" : currentListing.websiteVideoRelPath != nil ? "Publish listing" : "Publish tour", "icloud.and.arrow.up")
                }
                .buttonStyle(ScalePressStyle())
                .accessibilityIdentifier("phase1.publish")
            }
        }
        .padding(14)
        .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func createTourCard(_ a: CaptureAsset) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            nextStepHeader("sparkles", "Create your tour",
                           "Your walkthrough is here. Tag \(space == .realEstate ? "rooms" : "areas"), pick a look, and Rendprop renders the flythrough on your phone.")
            lastErrorBanner
            NavigationLink {
                ReviewSubmitView(listing: currentListing, asset: a)
            } label: {
                nextStepLabel((currentListing.lastError ?? "").isEmpty ? "Create tour" : "Try the render again", "sparkles")
            }
            .buttonStyle(ScalePressStyle())
        }
        .padding(14)
        .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var addVideoCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            nextStepHeader("video.badge.plus", "Add a walkthrough video",
                           "Optional: record a steady walkthrough or upload existing footage. Your photo-based listing video and property website work without it.")
            lastErrorBanner
            NavigationLink {
                AddVideoFlowView(listing: currentListing)
            } label: {
                nextStepLabel("Add walkthrough video", "video.badge.plus")
            }
            .buttonStyle(ScalePressStyle())
        }
        .padding(14)
        .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var sampleCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            nextStepHeader("sparkles", "This is a sample",
                           "Sample tours are demos — they never publish. Create your own \(space.spaceNoun) to get a real share link, leads, and every tool below.")
            NavigationLink {
                NewListingView()
            } label: {
                nextStepLabel("Create a \(space.spaceNoun)", "plus.viewfinder")
            }
            .buttonStyle(ScalePressStyle())
        }
        .padding(14)
        .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// Nominal section/grid/tile boundaries keep the toolbox's navigation and
    /// card modifier trees out of this screen's enclosing SwiftUI metadata.
    private var toolboxSection: ListingToolboxSection {
        ListingToolboxSection(grid: ListingToolboxGrid(
            listing: currentListing, destinationListing: { currentListing }, space: space, asset: asset,
            canRerender: asset != nil && availableRerenderSource == asset?.localURL,
            canTagRooms: canTagRooms,
            hasPublishedTour: tour != nil || shareURL != nil,
            // Reuse the background FILES scan. No disk reads in body.
            photoCount: mediaItems.filter { $0.kind == .photo }.count,
            openReel: { showReelStudio = true },
            openRoomTagger: { openRoomTags() },
            sharePackage: { shareListingPackage() },
            hasAnythingToShare: !mediaItems.isEmpty
        ), resumeAerial: !currentListing.isSample && PendingAerialJob.load(for: currentListing.id) != nil
            ? { showAerialIntro = true } : nil)
    }

    // MARK: - Files (the 4,000 sq ft field test)

    /// Everything this listing has made, on the listing screen, in one place.
    ///
    /// THE DEFECT, in the owner's words after the 4,000 sq ft field test: "I don't
    /// have any of the photos or videos I made saved, I can't see them after I use
    /// the feature. Like all those features and photos should be saved in the house
    /// files. They all cost credits, I can't be losing them."
    ///
    /// Every one of these files ALREADY survived relaunch. Not one of them was
    /// reachable from here. A finished reel sat four navigation levels deep inside
    /// Reel Studio, behind a sign-in gate, and even there only the newest one was
    /// ever shown. The aerial was attached to the listing and restored correctly
    /// with nothing on this screen that read as "your video is in here". The photo
    /// studio's own grid is the one thing that worked, and this section copies it.
    ///
    /// NOT sign-in gated, deliberately: these are files on the agent's own phone
    /// that he has already paid for, and an expired session is no reason to hide
    /// them. Samples are excluded — a sample's files are the bundled demo's, not
    /// his (`loadFiles`).
    ///
    /// WHAT THE SECOND PASS CHANGED, and why. Build 8 shipped it as a list of
    /// rows whose only action was a LONG-PRESS. Reading it cold as a 55-year-old
    /// agent who is not technical: the names were ours and not his ("Motion
    /// clip"), the one thing he wants to do — get the video into his camera roll
    /// — was an invisible gesture, "Saved to Photos" was a grey caption easy to
    /// miss, and on a listing that had made nothing the whole card vanished, so
    /// the screen that answers "where did my stuff go?" appeared only to people
    /// who no longer needed to ask. All four are fixed here; the long-press menu
    /// stays for anyone who already found it.
    @ViewBuilder private var filesSection: some View {
        // SHOWN EVEN WHEN EMPTY (on a real listing). It used to vanish entirely
        // with no files, which meant the one screen that answers "where did my
        // stuff go?" only appeared to people who already knew the answer. An
        // empty FILES card that says what will land in it is the promise; a
        // missing card is nothing at all. Samples still show none — a sample's
        // files are the bundled demo's, not his (`loadFiles`).
        if !currentListing.isSample {
            VStack(alignment: .leading, spacing: 12) {
                filesHeader
                if mediaItems.isEmpty {
                    // Gated on `filesStamp`, which is nil ONLY until the first
                    // scan lands. The scan runs off the main thread now (the
                    // build-9 lag report), so for the frame or two before its
                    // first result arrives an empty `mediaItems` is not yet an
                    // answer — and "Nothing here yet." is a claim, not a
                    // placeholder. Build 8 scanned synchronously and so never
                    // showed this card to a listing that had files; this keeps
                    // that exactly true. Nothing about what the card SAYS or
                    // how it looks changed, only when it is entitled to appear.
                    if filesStamp != nil { filesEmpty }
                } else {
                    Text("Everything you've made for this \(space.spaceNoun), saved on this phone. Tap one to open it. Tap Save to put it in your Photos app.")
                        .font(.rpCaption).foregroundStyle(Theme.inkDim)
                        .fixedSize(horizontal: false, vertical: true)
                    if filePhotos.count > 1 { shareAllFilePhotosButton }
                    ForEach(fileRows) { item in fileRow(item) }
                    filePhotoGrid
                }
                if let filesNote { filesNoteRow(filesNote) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
    }

    /// Richard's ask after the first listings went out: "transfer a house with
    /// pictures out to my transaction coordinator… you have to make it easy so
    /// an agent can just share it with a person that handles their file." One
    /// tap here opens the export sheet with every photo of this listing and
    /// packages them as a single ZIP (with the disclosure notes) by default.
    private var shareAllFilePhotosButton: some View {
        Button { shareAllFilePhotos() } label: {
            Label("Share all \(filePhotos.count) photos", systemImage: "square.and.arrow.up")
                .font(.rpBody.weight(.semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .modifier(RendpropActionLabelSurface(primary: true))
        }
        .accessibilityIdentifier("detail.files.shareAllPhotos")
        .accessibilityHint(Text("Opens the export sheet with every photo as one ZIP file to send to a transaction coordinator or client."))
    }

    @MainActor private func shareAllFilePhotos() {
        let admission = mediaExportAdmission(for: currentListing)
        let items = filePhotos
        guard !items.isEmpty, admission() else { return }
        let photos = items.map { item -> EnhancedPhoto in
            let photoID = item.id.hasPrefix("photo-") ? String(item.id.dropFirst("photo-".count)) : item.id
            return EnhancedPhoto(id: photoID, originalURL: item.originalURL ?? item.url, enhancedURL: item.url)
        }
        filePhotoExportAdmission = admission
        filePackageExtras = []
        filePhotoExport = PhotoExportSelection(photos: photos)
    }

    /// Build 60 — "Share everything": the whole listing as one hand-over. Every
    /// file the FILES card already lists (the same background scan, no disk
    /// reads here) plus a details note: address, the facts, the share links.
    /// Photos go through the ordinary export (JPEG copies, disclosure notes,
    /// retained originals); videos and the scan are read straight from where
    /// they live, never copied or moved.
    @MainActor private func shareListingPackage() {
        let admission = mediaExportAdmission(for: currentListing)
        let items = mediaItems
        guard !items.isEmpty, admission() else { return }
        // A stale scan must not silently turn "everything" into a partial
        // handover. Preparation also rechecks sources while reading the ZIP.
        guard items.allSatisfy({ FileManager.default.fileExists(atPath: $0.url.path) }) else {
            packageError = "A listing file is no longer available on this phone. Reopen the listing to refresh its files, then try again."
            return
        }
        let photos = items.filter { $0.kind == .photo }.map { item -> EnhancedPhoto in
            let photoID = item.id.hasPrefix("photo-") ? String(item.id.dropFirst("photo-".count)) : item.id
            return EnhancedPhoto(id: photoID, originalURL: item.originalURL ?? item.url, enhancedURL: item.url)
        }
        var extras: [PhotoExportRenderer.Extra] = []
        var counts: [ListingMediaItem.Kind: Int] = [:]
        for item in items.sorted(by: { $0.createdAt < $1.createdAt }) where item.kind != .photo {
            counts[item.kind, default: 0] += 1
            let n = counts[item.kind] ?? 1
            let ext = item.url.pathExtension.isEmpty ? (item.isVideo ? "mp4" : "bin") : item.url.pathExtension
            let stem: String
            switch item.kind {
            case .tour:       stem = n == 1 ? "walkthrough-tour" : "walkthrough-tour-\(n)"
            case .reel:       stem = "reel-\(String(format: "%02d", n))"
            case .aerial:     stem = n == 1 ? "aerial-intro" : "aerial-intro-\(n)"
            case .motionClip: stem = "moving-photo-\(String(format: "%02d", n))"
            case .floorPlan:  stem = n == 1 ? "3d-floor-plan" : "3d-floor-plan-\(n)"
            case .photo:      continue
            }
            let note: String
            switch item.kind {
            case .tour:       note = "the walkthrough tour video people scroll through on the listing page"
            case .reel:       note = "a social reel (AI motion from the listing photos)"
            case .aerial:     note = "the AI-generated aerial opening — not real drone footage"
            case .motionClip: note = "one photo turned into a short AI-motion clip"
            case .floorPlan:  note = "the 3D scan (open on a Mac, PC or phone that can show 3D files)"
            case .photo:      continue
            }
            extras.append(PhotoExportRenderer.Extra(name: "\(stem).\(ext)", url: item.url, note: note))
        }
        do {
            let note = try Self.listingDetailsNote(for: currentListing)
            extras.append(PhotoExportRenderer.Extra(name: "listing-details.txt", url: note,
                                                    note: "the address, the facts on the listing page and the share links"))
        } catch {
            packageError = "Couldn't save the listing details for this package. Free some space and try again."
            return
        }
        guard !photos.isEmpty || !extras.isEmpty else { return }
        filePhotoExportAdmission = admission
        filePackageExtras = extras
        filePhotoExport = PhotoExportSelection(photos: photos)
    }

    /// A plain-text note for the package: what the listing says about itself,
    /// in the words on the listing page, plus the public links. Written to the
    /// temporary directory; the usual cleanup removes it.
    private static func listingDetailsNote(for listing: Listing) throws -> URL {
        var lines: [String] = [listing.address.isEmpty ? "Untitled listing" : listing.address, ""]
        if let tagline = listing.tagline?.trimmingCharacters(in: .whitespacesAndNewlines), !tagline.isEmpty { lines.append(tagline); lines.append("") }
        let chips = listing.cardChips
        if !chips.isEmpty { lines.append(chips.joined(separator: " · ")); lines.append("") }
        if let url = listing.serverShareURL { lines.append("Listing page: \(url.absoluteString)") }
        if let url = listing.serverUnbrandedURL { lines.append("MLS-safe page (no branding): \(url.absoluteString)") }
        if let sold = listing.soldAt {
            let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none
            lines.append("Marked sold on \(f.string(from: sold))")
        }
        let f = DateFormatter(); f.dateStyle = .long; f.timeStyle = .short
        lines.append("")
        lines.append("Exported from Rendprop on \(f.string(from: Date())). Photos made or changed with AI carry their own disclosure notes in this package.")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Rendprop-details-\(UUID().uuidString).txt")
        try Data(lines.joined(separator: "\n").utf8).write(to: url, options: .atomic)
        return url
    }

    private var filesHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("YOUR FILES").font(.rpKicker).foregroundStyle(Theme.inkDim)
            Spacer(minLength: 8)
            if !mediaItems.isEmpty {
                Text("\(mediaItems.count) file\(mediaItems.count == 1 ? "" : "s")")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.inkDim)
            }
        }
    }

    /// Nothing made yet. Says what WILL appear here and that it is kept — which
    /// is the whole anxiety this section exists to answer.
    private var filesEmpty: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Nothing here yet.")
                .font(.rpBody.weight(.semibold))
                .foregroundStyle(Theme.ink)
            Text("Your saved photos and videos stay on this phone. You can put them in your Photos app with one tap.")
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The tour, the reels, the flyover, the moving photos and the floor plan —
    /// one row each, the shape the photo studio's MOTION CLIPS card already uses.
    private var fileRows: [ListingMediaItem] { mediaItems.filter { $0.kind != .photo } }

    /// The photos, in the same two-up grid the photo studio shows them in.
    private var filePhotos: [ListingMediaItem] { mediaItems.filter { $0.kind == .photo } }

    @ViewBuilder private var filePhotoGrid: some View {
        if !filePhotos.isEmpty {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(filePhotos) { item in filePhotoCell(item) }
            }
        }
    }

    /// One file: tap the row to open it, tap the button on the right to save it.
    ///
    /// The row used to be a single Button with a chevron and a `contextMenu`, so
    /// the ONLY way to get a reel into the camera roll from here was a long-press
    /// — an invisible gesture most people over about forty have never been taught
    /// and none of them will discover. The two controls are SIBLINGS in an HStack
    /// rather than a button inside a button: SwiftUI's outer button swallows taps
    /// meant for a nested one, which would have looked like the save button
    /// simply not working.
    private func fileRow(_ item: ListingMediaItem) -> some View {
        HStack(spacing: 10) {
            Button { openFile(item) } label: {
                HStack(spacing: 12) {
                    MediaThumb(item: item)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.rpBody.weight(.semibold)).foregroundStyle(Theme.ink)
                        Text(item.blurb)
                            .font(.rpCaption).foregroundStyle(Theme.inkDim)
                            .lineLimit(1).minimumScaleFactor(0.8)
                        Text(item.dateLabel)
                            .font(.caption2).foregroundStyle(Theme.inkDim)
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(ScalePressStyle())
            .accessibilityLabel(Text("\(item.title). \(item.blurb). \(item.dateLabel). Opens it."))
            fileActionButton(item)
        }
        .padding(10)
        .background(Theme.fillSubtle,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contextMenu { fileMenu(item) }
    }

    /// Save (everything that is a photo or a video) or Share (the 3D floor plan,
    /// which Photos cannot hold). Labelled with a WORD, not just a glyph — an
    /// arrow-into-a-tray means "save" only to people who already knew.
    @ViewBuilder private func fileActionButton(_ item: ListingMediaItem) -> some View {
        if item.savesToPhotos {
            let done = savedFiles.contains(item.id)
            Button { saveFileToPhotos(item) } label: {
                filePill(done ? "Saved" : "Save",
                         done ? "checkmark.circle.fill" : "square.and.arrow.down",
                         done: done)
            }
            .buttonStyle(.plain)
            .disabled(isSavingFile)
            .accessibilityLabel(Text(done
                ? "\(item.title) is in your Photos app"
                : "Save \(item.title) to your Photos app"))
        } else {
            ShareLink(item: item.url) {
                filePill("Share", "square.and.arrow.up", done: false)
            }
            .accessibilityLabel(Text("Share \(item.title)"))
        }
    }

    /// A 60×52 target with the word under the glyph. Comfortably past the 44 pt
    /// minimum in both directions.
    private func filePill(_ title: String, _ icon: String, done: Bool) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
            Text(title)
                .font(.caption2.weight(.semibold))
        }
        .frame(width: 60, height: 52)
        .foregroundStyle(done ? Theme.good : Theme.accent)
        .background(done ? Theme.fillSubtle : Theme.accentSoft,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func filePhotoPublicationLabel(_ item: ListingMediaItem) -> String? {
        guard let current = model.listings.first(where: { $0.id == listing.id }), current.serverID != nil else {
            return item.publicationLabel
        }
        let id = String(item.id.dropFirst("photo-".count))
        return model.cloudPhotoProjection(for: listing.id)?.label(versionID: id) ?? "Check listing selection"
    }
    private func filePhotoPublicationKnown(_ item: ListingMediaItem) -> Bool {
        let label = filePhotoPublicationLabel(item)
        return label == "Selected for listing" || label == "Another version on listing"
            || (model.listings.first(where: { $0.id == listing.id })?.serverID == nil
                && label != nil && label != "Not selected for listing")
    }
    private func filePhotoCell(_ item: ListingMediaItem) -> some View {
        Button { openFile(item) } label: {
            VStack(alignment: .leading, spacing: 6) {
                DetailPhotoThumb(url: item.url, height: 110)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Theme.border))
                Text(item.dateLabel)
                    .font(.caption2).foregroundStyle(Theme.inkDim)
                    .lineLimit(1).minimumScaleFactor(0.8)
                // Reserve the status line so adjacent thumbnails keep their
                // top edges aligned when the selected version is a predecessor.
                Label(filePhotoPublicationLabel(item) ?? "Selection unavailable", systemImage: filePhotoPublicationKnown(item) ? "checkmark.circle.fill" : "circle")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(filePhotoPublicationKnown(item) ? Theme.good : Theme.inkDim)
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
        }
        .buttonStyle(ScalePressStyle())
        .accessibilityLabel(Text("Photo. \(item.dateLabel). Opens before and after."))
        .accessibilityValue(filePhotoPublicationLabel(item) ?? "Selection unavailable")
        .accessibilityIdentifier("listing.filePhoto.\(item.id)")
        // Keep the save action outside the label AND outside the open button's
        // accessibility modifiers, so VoiceOver does not call Save an opener.
        .overlay(alignment: .topTrailing) { photoSaveBadge(item) }
        .contextMenu { fileMenu(item) }
    }

    /// The photo grid's save button. Small, because the cell is small — but a
    /// real button in the corner of every picture beats a long-press nobody
    /// performs.
    private func photoSaveBadge(_ item: ListingMediaItem) -> some View {
        let done = savedFiles.contains(item.id)
        return Button { saveFileToPhotos(item) } label: {
            Image(systemName: done ? "checkmark.circle.fill" : "square.and.arrow.down")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(done ? Theme.good : Theme.accent)
                .frame(width: 40, height: 40)
                .background(.ultraThinMaterial, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isSavingFile)
        .padding(4)
        .accessibilityLabel(Text(done ? "This photo is in your Photos app"
                                      : "Save this photo to your Photos app"))
        .accessibilityIdentifier("listing.savePhoto.\(item.id)")
    }

    /// What happened to the last save, in a colour and with an icon rather than a
    /// grey caption. "Saved to Photos" was true and easy to miss; naming the app
    /// it landed in is the difference between a person finding it and a person
    /// tapping Save a second time.
    private func filesNoteRow(_ text: String) -> some View {
        Label(text, systemImage: filesNoteOK ? "checkmark.circle.fill"
                                             : "exclamationmark.triangle.fill")
            .font(.rpBody.weight(.semibold))
            .foregroundStyle(filesNoteOK ? Theme.good : Theme.warn)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Theme.fillSubtle,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityAddTraits(.isStaticText)
    }

    @ViewBuilder private func fileMenu(_ item: ListingMediaItem) -> some View {
        // Kept as well as the buttons, not instead of them: somebody who already
        // knows the long-press should still find it there.
        if item.savesToPhotos {
            Button { saveFileToPhotos(item) } label: {
                Label("Save to Photos", systemImage: "square.and.arrow.down")
            }
        }
        if item.kind == .photo {
            Button { downloadJPEG(item) } label: {
                Label("Download JPEG for MLS", systemImage: "doc.badge.arrow.down")
            }
        }
        if item.kind == .photo {
            Button { downloadJPEG(item) } label: {
                Label("Share photo", systemImage: "square.and.arrow.up")
            }
        } else {
            ShareLink(item: item.url) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
    }

    @MainActor private func downloadJPEG(_ item: ListingMediaItem) {
        let admission = mediaExportAdmission(for: currentListing)
        guard item.kind == .photo, admission() else { return }
        let photoID = item.id.hasPrefix("photo-") ? String(item.id.dropFirst("photo-".count)) : item.id
        filePhotoExportAdmission = admission
        filePhotoExport = PhotoExportSelection(photos: [EnhancedPhoto(id: photoID,
            originalURL: item.originalURL ?? item.url, enhancedURL: item.url)])
    }

    private func openFile(_ item: ListingMediaItem) {
        Haptics.selection()
        openedFile = item
    }

    /// Copy one file into the user's Photos library. Videos and photo FILES take
    /// different `PhotosLibrarySaver` calls — `saveImageFile` writes the exact
    /// bytes rather than re-encoding, which matters when the "photo" is a
    /// compliance original a broker may ask for (W2-C2).
    @MainActor private func saveFileToPhotos(_ item: ListingMediaItem) {
        guard !isSavingFile else { return }
        let canExport = mediaExportAdmission(for: currentListing)
        guard canExport() else { return }
        isSavingFile = true
        filesNote = nil
        let url = item.url
        let isVideo = item.isVideo
        let what = item.title
        let id = item.id
        let kind = item.kind.rawValue
        Task { @MainActor in
            defer { isSavingFile = false }
            do {
                if isVideo {
                    try await PhotosLibrarySaver.saveVideo(at: url, while: canExport)
                } else {
                    try await PhotosLibrarySaver.saveImageFile(at: url, while: canExport)
                }
                guard canExport() else { return }
                savedFiles.insert(id)
                filesNoteOK = true
                filesNote = "\(what) is now in your Photos app."
                Haptics.success()
                Analytics.track("file_saved", ["kind": kind, "ok": "true"])
            } catch {
                guard canExport() else { return }
                filesNoteOK = false
                filesNote = error.localizedDescription
                Analytics.track("file_saved", ["kind": kind, "ok": "false"])
            }
        }
    }

    /// Read the listing's files off disk. Samples are skipped: a sample's "tour"
    /// is the bundled demo and its studios are disabled (decision A7), so listing
    /// files for one would be a promise about media that is not the agent's.
    ///
    /// THE BUILD-9 LAG REPORT — "laggy as hell — that will kill the business".
    /// This function is where that came from, and it was mine. Build 8 called a
    /// `@MainActor` scan straight from `onAppear`, so before the listing screen
    /// could draw a single pixel it ran, synchronously, on the main thread:
    /// three `contentsOfDirectory` calls (one of them twice over the same
    /// folder), a `fileExists` per photo looking for its "before", and a
    /// creation-date stat per file — inside the sort comparators, so O(n log n)
    /// of them. On the owner's listing, seventeen room tags and a large photo
    /// set, that is comfortably over fifty synchronous filesystem calls in front
    /// of the first frame, every single time this screen appeared.
    ///
    /// Three things changed, and only these three:
    ///
    /// 1. The scan runs on a background thread and comes back in ONE hop
    ///    (`ListingMediaItem.scan`). Nothing about the list it produces changed.
    /// 2. It is skipped entirely when nothing on disk has moved, which is the
    ///    common case: `ScanStamp` is five modification dates, and an unchanged
    ///    stamp returns nil and leaves `mediaItems` — and therefore every row's
    ///    thumbnail task — exactly as they were.
    /// 3. `force` says "a screen that could have written a file just closed",
    ///    which skips the stamp check. Only the aerial sheet needs it: it can
    ///    write a flyover AND, through its own Reel Studio cover, a reel.
    ///
    /// STALENESS is the thing this must not trade for speed, so the stamp covers
    /// every writer: `reels/`, `Photos/<id>/` (photos AND motion clips),
    /// `FloorPlans/`, the aerial's own file, and the rendered tour — which lives
    /// at a path this screen doesn't own and is rewritten IN PLACE by a
    /// re-render, hence its modification date and not merely its URL. The photo
    /// studio, the floor-plan scanner and Reel Studio are all pushes, so their
    /// pop-back runs the stamp check and picks up whatever they wrote.
    private func loadFiles(force: Bool = false) {
        guard hasCurrentPresentationContext else { invalidatePresentation(); return }
        let expectedScope = presentationScope
        let live = currentListing
        guard !live.isSample else {
            filesTask?.cancel()
            filesTask = nil
            filesStamp = nil
            mediaItems = []
            return
        }
        // Snapshot everything the scan needs HERE, on the main actor, so the
        // scan itself never reaches back for the model or the view.
        let request = ListingMediaItem.ScanRequest(listingID: live.id,
                                                   tourURL: tour?.url,
                                                   aerialRelPath: live.aerialRelPath,
                                                   aerialGeneratedAt: live.aerialGeneratedAt)
        let since = force ? nil : filesStamp
        filesTask?.cancel()
        filesTask = Task {
            if live.serverID != nil { _ = try? await model.refreshCloudPhotoSelection(listingID: live.id) }
            guard !Task.isCancelled, expectedScope == presentationScope, hasCurrentPresentationContext else { return }
            guard let scan = await ListingMediaItem.scan(request, since: since) else { return }
            guard !Task.isCancelled, expectedScope == presentationScope,
                  hasCurrentPresentationContext else { return }
            filesStamp = scan.stamp
            // Only publish a list that is actually different. An equal array
            // still invalidates `@State` and re-runs `body`, which on this screen
            // means re-laying out every file row for no reason.
            if scan.items != mediaItems { mediaItems = scan.items }
        }
    }

    // MARK: - Compliance (W2-C2)

    /// Keep the record accessible without making the listing's main tool feed
    /// a long disclosure log. Expanding retains all original records/actions.
    @ViewBuilder private var complianceSection: some View {
        if !currentListing.isSample, currentListing.serverID != nil,
           !provenance.isEmpty || isLoadingProvenance || provenanceError != nil {
            DisclosureGroup(isExpanded: $showComplianceDetails) {
                complianceDetails
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Disclosures & originals")
                            .font(.rpBody.weight(.semibold)).foregroundStyle(Theme.ink)
                        Text(!provenance.isEmpty
                             ? "\(provenance.count) AI media items · disclosure log"
                             : isLoadingProvenance ? "Loading the disclosure log…" : "Disclosure log needs attention")
                            .font(.rpCaption)
                            .foregroundStyle(provenanceError == nil ? Theme.inkDim : Theme.warn)
                    }
                    Spacer(minLength: 0)
                }
            }
            .tint(Theme.accent)
            .padding(16)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius))
            .accessibilityIdentifier("listing.photoCompliance")
        }
    }

    /// Every AI-altered or AI-generated asset on this listing, with the exact
    /// disclosure sentence the public tour prints, a link to the unaltered
    /// original, and the two things a broker actually asks for: the originals on
    /// file and the audit log as a CSV.
    ///
    /// Hidden until there is something to disclose. A listing with no
    /// provenance rows gets NO reassuring "nothing was altered" line — rows
    /// only exist from the compliance wave forward, so that claim could be
    /// false for media generated by an earlier build.
    @ViewBuilder private var complianceDetails: some View {
        if !currentListing.isSample, currentListing.serverID != nil,
           !provenance.isEmpty || isLoadingProvenance || provenanceError != nil {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("COMPLIANCE").font(.rpKicker).foregroundStyle(Theme.inkDim)
                    Spacer(minLength: 8)
                    if !provenance.isEmpty {
                        Text("\(provenance.count) altered")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.inkDim)
                    }
                }

                // AB 723 is a real-estate LISTING statute (digitally altered
                // listing imagery). A Sausalito wine bar gets the same
                // disclosure rows — Rendprop labels AI-altered media everywhere
                // — but not a claim of law that does not apply to it (P1-5).
                if space == .realEstate, currentListing.isCalifornia {
                    Label("California requires disclosure and access to originals for altered listing media (AB 723).",
                          systemImage: "exclamationmark.shield.fill")
                        .font(.rpCaption.weight(.semibold))
                        .foregroundStyle(Theme.warn)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Theme.warn.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                if isLoadingProvenance && provenance.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Loading the disclosure log…")
                            .font(.rpCaption).foregroundStyle(Theme.inkDim)
                    }
                } else if let provenanceError, provenance.isEmpty {
                    Text(provenanceError)
                        .font(.rpCaption).foregroundStyle(Theme.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ForEach(provenance) { row in
                    provenanceRow(row)
                }

                if !provenance.isEmpty {
                    Text(space == .realEstate
                         ? "These sentences are published on both your links — disclosure is property information, so it stays on the unbranded page too."
                         : "These sentences are published with your tour — every AI-altered photo or clip is labelled wherever the link goes.")
                        .font(.rpCaption)
                        .foregroundStyle(Theme.inkDim)
                        .fixedSize(horizontal: false, vertical: true)

                    Button { saveOriginalsToPhotos() } label: {
                        Label(isSavingOriginals ? "Saving originals…" : "Download originals",
                              systemImage: "square.and.arrow.down")
                            .font(.rpBody.weight(.semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .modifier(RendpropActionLabelSurface(primary: false))
                    }
                    .disabled(isSavingOriginals || !provenance.contains(where: { $0.hasOriginal }))

                    Button { exportAudit() } label: {
                        Label(isExportingAudit ? "Building the audit…"
                                : (space == .realEstate ? "Email my broker the audit" : "Export the audit log"),
                              systemImage: "doc.text")
                            .font(.rpBody.weight(.semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .modifier(RendpropActionLabelSurface(primary: false))
                    }
                    .disabled(isExportingAudit)
                }

                if let complianceNote {
                    Text(complianceNote)
                        .font(.rpCaption)
                        .foregroundStyle(Theme.inkDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
    }

    /// One altered asset. GREEN when the unaltered original is on file (the
    /// disclosure AND the access half of AB 723 are both satisfied); AMBER when
    /// it is not. `disclosure` is printed VERBATIM — it is the legally-required
    /// sentence, not copy we are free to tighten.
    private func provenanceRow(_ r: ProvenanceRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: r.hasOriginal ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.rpCaption.weight(.bold))
                    .foregroundStyle(r.hasOriginal ? Theme.good : Theme.warn)
                Text(r.displayLabel)
                    .font(.rpBody.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 8)
                Text(r.model)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Theme.fillSubtle, in: Capsule())
                    .foregroundStyle(Theme.inkDim)
            }
            Text(r.disclosure)
                .font(.rpCaption)
                .foregroundStyle(Theme.inkDim)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                if let original = r.originalURL {
                    Link(destination: original) {
                        Label("View original", systemImage: "arrow.up.right.square")
                            .font(.rpCaption.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                    }
                } else {
                    Label("No original on file", systemImage: "exclamationmark.triangle")
                        .font(.rpCaption)
                        .foregroundStyle(Theme.warn)
                }
                Spacer(minLength: 0)
                if let created = r.createdAt {
                    Text(created.formatted(date: .abbreviated, time: .omitted))
                        .font(.rpCaption)
                        .foregroundStyle(Theme.inkDim)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.fillSubtle, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// Manage — edit, sold/archived, Zillow (real estate), delete. Hidden for
    /// samples entirely.
    private var manageSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MANAGE").font(.rpKicker).foregroundStyle(Theme.inkDim)

            Button { showEdit = true } label: {
                Label("Edit details", systemImage: "pencil")
                    .font(.rpBody.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }

            // setSold/setZillow mark the listing dirty and sync it to the server
            // themselves (decision A6) — nothing else to call here.
            Button {
                model.setSold(!currentListing.isInactive, for: listing.id)
                playerRefresh = UUID()
                Haptics.success()
            } label: {
                Label(currentListing.isInactive ? "Mark as active" : "Mark as \(space.archiveVerb)",
                      systemImage: currentListing.isInactive ? "arrow.uturn.backward" : "checkmark.seal.fill")
                    .font(.rpBody.weight(.semibold))
                    .foregroundStyle(currentListing.isInactive ? Theme.inkDim : Theme.accent)
            }

            // Zillow is a real-estate concept — a gym or bar never sees it.
            // Non-RE types manage their booking/reservation/store links
            // through the Details card's URL fields instead.
            if space == .realEstate {
                Divider()
                zillowRows
            }

            Divider()
            Button(role: .destructive) { showDeleteConfirm = true } label: {
                Label("Delete \(space.spaceNoun)", systemImage: "trash")
                    .font(.rpBody.weight(.semibold))
                    .foregroundStyle(Theme.bad)
            }
            Text(deleteMessage)
                .font(.rpCaption)
                .foregroundStyle(Theme.inkDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var deleteMessage: String {
        // Build 58: a cloud listing sits in Recently deleted for 30 days, so the
        // copy promises exactly what the server does — and no more for a local-only one.
        var text: String
        if currentListing.serverID != nil, Config.useLiveBackend {
            text = currentListing.serverShareURL != nil
                ? "Removes the video, photos and tour from this phone and takes both share links offline. You can restore it from Settings › Recently deleted for 30 days; the same links come back."
                : "Removes the video, photos and tour from this phone. You can restore the cloud copy from Settings › Recently deleted for 30 days."
        } else {
            text = "Removes the video, photos and tour from this phone. This can't be undone."
        }
        // W2-C3: an original that backs a disclosed AI edit is evidence. Deleting
        // the listing wipes this phone's copy of it, so say so BEFORE the tap —
        // "Download originals" in COMPLIANCE is one scroll away.
        let backed = provenance.filter { $0.hasOriginal }.count
        if backed > 0 {
            let one = backed == 1
            let noun: String = one ? "photo" : "photos"
            let verb: String = one ? "has" : "have"
            let object: String = one ? "it" : "them"
            let subject: String = space == .realEstate ? "listing" : space.spaceNoun
            text += " \(backed) AI-altered \(noun) on this \(subject) \(verb) a published original behind \(object)"
            text += space == .realEstate
                ? " — download the originals from COMPLIANCE first if your broker needs them on file."
                : " — download the originals from COMPLIANCE first if you want to keep them on file."
        }
        return text
    }

    @ViewBuilder private var zillowRows: some View {
        Text("Zillow listing").font(.rpCaption).foregroundStyle(Theme.inkDim)
        HStack {
            TextField("Paste Zillow URL", text: $zillowText)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Save") { saveZillow() }
                .disabled(zillowText.trimmingCharacters(in: .whitespacesAndNewlines) == (currentListing.zillowURL ?? ""))
        }
        if let zillowError {
            Text(zillowError).font(.rpCaption).foregroundStyle(Theme.warn)
        }
        if let z = currentListing.zillowURLValue {
            Link(destination: z) {
                Label("View on Zillow", systemImage: "arrow.up.right.square")
                    .font(.rpCaption).foregroundStyle(Theme.accent)
            }
        }
    }

    /// Leads are the one metric that exists today. Views/watch time are not
    /// collected anywhere, so they are not promised (F-A-21).
    private var performanceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("LEADS").font(.rpKicker).foregroundStyle(Theme.inkDim)
            if currentListing.isSample {
                HStack(spacing: 10) {
                    statCard("12", "Leads", "person.crop.circle.badge.checkmark")
                    statCard("3", "This week", "calendar")
                }
                Text("Sample data — leads from your published tours land here.")
                    .font(.rpCaption)
                    .foregroundStyle(Theme.inkDim)
            } else if currentListing.serverID != nil {
                NavigationLink {
                    LeadsView(listing: currentListing)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 40, height: 40)
                            .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Leads").font(.rpHeadline).foregroundStyle(Theme.ink)
                            Text("Everyone who filled in the form on this tour's link.")
                                .font(.rpCaption).foregroundStyle(Theme.inkDim)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.rpCaption.weight(.bold)).foregroundStyle(Theme.inkDim)
                    }
                    .padding(12)
                    .background(Theme.fillSubtle, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(ScalePressStyle())
                Text("Enquiries from this tour's share link appear here.")
                    .font(.rpCaption)
                    .foregroundStyle(Theme.inkDim)
            } else {
                Label("Publish your tour to start collecting leads from the share link.",
                      systemImage: "person.crop.circle.badge.plus")
                    .font(.rpBody)
                    .foregroundStyle(Theme.inkDim)
                    .padding(.vertical, 8)
            }
        }
        .card()
    }

    private var subtitleText: String {
        [currentListing.subtitleLine,
         currentListing.price.cents > 0 ? currentListing.price.formatted : ""]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Text(currentListing.address).font(.rpTitle).foregroundStyle(Theme.ink)
                Spacer(minLength: 0)
                if !currentListing.isSample {
                    StatusChip(status: currentListing.status)
                }
            }
            if !subtitleText.isEmpty {
                Text(subtitleText)
                    .font(.rpBody)
                    .foregroundStyle(Theme.inkDim)
            }
            if let region = currentListing.regionLabel?.trimmingCharacters(in: .whitespaces), !region.isEmpty {
                Label(region, systemImage: "mappin")
                    .font(.rpCaption)
                    .foregroundStyle(Theme.inkDim)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    /// Business details (non real estate) — fields + action links.
    @ViewBuilder private var detailsSection: some View {
        if !space.showsPropertyDetails, !detailRowFields.isEmpty || !detailLinkFields.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("DETAILS").font(.rpKicker).foregroundStyle(Theme.inkDim)
                ForEach(detailRowFields) { f in
                    HStack(alignment: .top, spacing: 12) {
                        Text(f.label).font(.rpBody).foregroundStyle(Theme.inkDim)
                        Spacer()
                        Text(f.display(currentListing.detail(f.key)))
                            .font(.rpBody).foregroundStyle(Theme.ink)
                            .multilineTextAlignment(.trailing)
                    }
                }
                ForEach(detailLinkFields) { f in
                    if let url = normalizedURL(currentListing.detail(f.key)) {
                        Link(destination: url) {
                            Label(linkLabel(f), systemImage: "arrow.up.right.square")
                                .font(.rpBody.weight(.semibold))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
    }

    /// Location map (appears once the address geocodes).
    @ViewBuilder private var mapSection: some View {
        if let coord = mapCoordinate {
            VStack(alignment: .leading, spacing: 8) {
                Text("LOCATION").font(.rpKicker).foregroundStyle(Theme.inkDim)
                Map(coordinateRegion: .constant(
                        MKCoordinateRegion(center: coord,
                                           span: MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008))),
                    interactionModes: [],
                    annotationItems: [MapPin(coordinate: coord)]) { pin in
                    MapMarker(coordinate: pin.coordinate, tint: Theme.accent)
                }
                .frame(height: 170)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .allowsHitTesting(false)
                if let url = mapsURL(coord) {
                    Link(destination: url) {
                        Label("Open in Maps", systemImage: "arrow.up.right.square")
                            .font(.rpCaption).foregroundStyle(Theme.accent)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
    }

    /// Apple's Maps URL scheme treats `address` as a standalone parameter
    /// that displays a location without a coordinate — and `ll`, if present,
    /// takes precedence over it — so sending both would defeat the point.
    /// We send the address alone whenever we have one: the user already
    /// typed it, Maps geocodes it on Apple's end, and no coordinate (coarse
    /// or otherwise) needs to leave the device. Only a listing with no
    /// address at all falls back to `ll=`, and even then only the coarsened
    /// fix — never the precise on-device coordinate (2026-09 audit P0-6
    /// follow-up).
    private func mapsURL(_ c: CLLocationCoordinate2D) -> URL? {
        var comps = URLComponents(string: "https://maps.apple.com/")
        let address = currentListing.address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !address.isEmpty {
            comps?.queryItems = [URLQueryItem(name: "address", value: address)]
        } else {
            comps?.queryItems = [
                URLQueryItem(name: "ll", value: "\(coarseCoordinate(c.latitude)),\(coarseCoordinate(c.longitude))"),
            ]
        }
        return comps?.url
    }

    // MARK: - Actions

    /// Publish the EXISTING local render (no re-render). Retain this tap while
    /// the anonymous connection is recovered; registration is never required.
    private func publishNow(cellularApproved: Bool = false) {
        guard !isPublishing, tour != nil || currentListing.websiteVideoRelPath != nil, !currentListing.isSample,
              model.isInSelectedWorkspace(currentListing), currentListing.cloudUnavailable != true else { return }
        let context = NativeMediaExportContext()
        connection.run {
            guard context.isCurrent, !cellularApproved || publishCellularParked else { return }
            publishWithSession(cellularApproved: cellularApproved)
        }
    }

    /// Build 58. Same session fence as a first publish; the model decides
    /// whether the video has to go up again or only the details and photos.
    private func republishNow() {
        guard !isRepublishing, !isPublishing, !currentListing.isSample,
              model.isInSelectedWorkspace(currentListing), currentListing.cloudUnavailable != true else { return }
        let context = NativeMediaExportContext()
        connection.run {
            guard context.isCurrent else { return }
            isRepublishing = true
            republishFailure = nil
            Haptics.selection()
            let id = listing.id
            Task {
                do {
                    _ = try await model.republishExisting(listingID: id)
                    await MainActor.run {
                        isRepublishing = false
                        republishedAt = Date()
                        playerRefresh = UUID()
                        refreshPublishedVideo()
                        Haptics.success()
                        PhotoFeedbackQueue.shared.recordPublication(listingID: id, model: model)
                    }
                } catch {
                    await MainActor.run {
                        isRepublishing = false
                        republishFailure = AIFailure(error, title: "Couldn't republish")
                        refreshPublishedVideo()
                    }
                }
            }
        }
    }

    private func publishWithSession(cellularApproved: Bool = false) {
        guard !isPublishing, tour != nil || currentListing.websiteVideoRelPath != nil, !currentListing.isSample else { return }
        // The toggle above the button is the answer whether or not it was
        // touched: it shows this property's saved choice, or Off when unanswered, so publishing
        // without touching it has to mean what it says on screen. A no-op when
        // the listing already carries this answer.
        model.setSearchIndexing(listOnGoogle, for: listing.id)
        isPublishing = true
        publishFailure = nil
        Haptics.selection()
        let id = listing.id
        Task {
            do {
                _ = try await model.publishExisting(listingID: id, cellularApproved: cellularApproved)
                await MainActor.run {
                    isPublishing = false
                    playerRefresh = UUID()
                    refreshPublishedVideo()
                    Haptics.success()
                    ReviewPrompter.shared.tourPublished()
                    PhotoFeedbackQueue.shared.recordPublication(listingID: id, model: model)
                }
            } catch {
                await MainActor.run {
                    isPublishing = false
                    publishFailure = AIFailure(error, title: "Couldn't publish")
                }
            }
        }
    }

    private var listingFactsNeedReview: Bool {
        let value = currentListing
        return value.factsSync?.conflict == true || value.factsSync?.reviewRequired == true
            || (value.serverID != nil && value.needsServerSync == true && value.factsSync == nil)
    }

    @MainActor private func mediaExportAdmission(for snapshot: Listing) -> () -> Bool {
        let context = NativeMediaExportContext()
        return {
            guard context.isCurrent, self.hasCurrentPresentationContext,
                  let current = self.model.listings.first(where: { $0.id == snapshot.id }),
                  current.cloudUnavailable != true else { return false }
            return current.serverID == snapshot.serverID && current.serverOrgID == snapshot.serverOrgID
        }
    }

    @MainActor private func refreshClientContactIfCurrent() async {
        guard !Task.isCancelled, hasCurrentPresentationContext, !currentListing.isSample else { return }
        try? await model.refreshClientContact(for: listing.id)
    }

    /// Load this listing's provenance rows (GET /me/compliance?listing_id=).
    /// Silent when the account has no access or the route is missing — the card
    /// stays hidden rather than shouting at an agent who did nothing wrong.
    @MainActor private func loadCompliance() async {
        guard !Task.isCancelled, hasCurrentPresentationContext else { return }
        let expectedScope = presentationScope
        let l = currentListing
        guard !l.isSample, let serverID = l.serverID else { return }
        guard !Config.enableAuth || auth.isSignedIn else { return }
        guard !isLoadingProvenance else { return }
        let canExport = mediaExportAdmission(for: l)
        guard canExport() else { return }
        isLoadingProvenance = true
        provenanceError = nil
        defer { isLoadingProvenance = false }
        do {
            let rows = try await model.api.provenance(listingServerID: serverID)
            guard canExport(), expectedScope == presentationScope, hasCurrentPresentationContext else { return }
            provenance = rows
            provenanceCanExport = canExport
        } catch is CancellationError {
            // The screen was left mid-load (a push cancels `.task`) — say nothing;
            // coming back re-runs it.
        } catch {
            guard expectedScope == presentationScope, hasCurrentPresentationContext else { return }
            if (error as? URLError)?.code == .cancelled { return }
            if let api = error as? APIError, api.isNotFound || api.isUnauthorized || api.isForbidden {
                provenanceError = nil    // nothing to show, and nothing the agent can fix here
            } else {
                provenanceError = "Couldn't load the disclosure log — \(AIFailure(error).message)"
            }
        }
    }

    /// Save every unaltered original this listing has on file into Photos —
    /// what a broker or a compliance officer asks for when they want the
    /// "before" images out of the app.
    @MainActor private func saveOriginalsToPhotos() {
        guard !isSavingOriginals else { return }
        guard let canExport = provenanceCanExport, canExport() else {
            complianceNote = "Your account, workspace or listing changed. Reopen the listing to download originals."
            return
        }
        let urls = provenance.compactMap { $0.originalURL }
        guard !urls.isEmpty else { return }
        isSavingOriginals = true
        complianceNote = nil
        Haptics.selection()
        Task { @MainActor in
            defer { isSavingOriginals = false }
            var saved = 0
            var failure: String?
            for remote in urls {
                var staged: URL?
                do {
                    try Task.checkCancellation()
                    guard canExport() else { return }
                    let (tmp, response) = try await URLSession.shared.download(from: remote)
                    // This operation owns only its returned temporary download.
                    // A rejected late reply cannot reach Photos or another URL.
                    defer { try? FileManager.default.removeItem(at: tmp) }
                    try Task.checkCancellation()
                    guard canExport() else { return }
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        try? FileManager.default.removeItem(at: tmp)
                        throw AIImagePrep.error("The original couldn't be downloaded (HTTP \(http.statusCode)).")
                    }
                    // Photos types the asset from the extension; the downloaded
                    // temp file has none. Keep the bytes untouched.
                    let ext = remote.pathExtension.isEmpty ? "jpg" : remote.pathExtension
                    let dest = FileManager.default.temporaryDirectory
                        .appendingPathComponent("original-\(UUID().uuidString).\(ext)")
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.moveItem(at: tmp, to: dest)
                    staged = dest
                    try await PhotosLibrarySaver.saveImageFile(at: dest, while: canExport)
                    guard canExport() else {
                        try? FileManager.default.removeItem(at: dest)
                        return
                    }
                    saved += 1
                } catch {
                    if failure == nil { failure = AIFailure(error).message }
                }
                if let staged { try? FileManager.default.removeItem(at: staged) }
            }
            let total = urls.count
            let done = saved
            let why = failure
            guard canExport() else { return }
            let plural: String = done == 1 ? "" : "s"
            if done == total {
                complianceNote = "Saved \(done) original\(plural) to Photos."
                Haptics.success()
            } else if done > 0 {
                complianceNote = "Saved \(done) of \(total) originals to Photos. \(why ?? "")"
            } else {
                complianceNote = why ?? "Couldn't save the originals."
            }
        }
    }

    /// Fetch the broker-exportable CSV for this listing and hand it to the share
    /// sheet, so "email my broker the audit" is one tap and a real attachment.
    @MainActor private func exportAudit() {
        guard !isExportingAudit, let serverID = currentListing.serverID else { return }
        let canExport = mediaExportAdmission(for: currentListing)
        guard canExport() else { return }
        isExportingAudit = true
        complianceNote = nil
        Haptics.selection()
        let api = model.api               // snapshot on the main actor
        let address = currentListing.address
        Task { @MainActor in
            var ownedDirectory: URL?
            var handedOff = false
            defer {
                isExportingAudit = false
                if !handedOff, let ownedDirectory { try? FileManager.default.removeItem(at: ownedDirectory) }
            }
            do {
                let csv = try await api.complianceCSV(listingServerID: serverID)
                try Task.checkCancellation()
                guard canExport() else { return }
                let name = Self.auditFilename(for: address)
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Rendprop-audit-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                ownedDirectory = directory
                let dest = directory.appendingPathComponent(name)
                try csv.write(to: dest, options: .atomic)
                guard canExport() else { return }
                auditExport = AuditExport(url: dest)
                handedOff = true
                Haptics.success()
            } catch {
                guard canExport() else { return }
                complianceNote = "Couldn't build the audit export — \(AIFailure(error).message)"
            }
        }
    }

    /// `rendprop-ai-disclosure-<address>-<yyyy-MM-dd>.csv`, filesystem-safe.
    static func auditFilename(for address: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let slug = address.unicodeScalars
            .map { allowed.contains($0) ? Character($0) : "-" }
            .reduce(into: "") { out, c in
                if c == "-" && out.hasSuffix("-") { return }
                out.append(c)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            .lowercased()
        let stamp = ISO8601DateFormatter().string(from: Date()).prefix(10)
        let base = slug.isEmpty ? "listing" : String(slug.prefix(40))
        return "rendprop-ai-disclosure-\(base)-\(stamp).csv"
    }

    private func deleteListing() {
        guard !isDeleting, !currentListing.isSample else { return }
        isDeleting = true
        let id = listing.id
        Task {
            await model.remove(id)
            await MainActor.run {
                isDeleting = false
                Haptics.success()
                dismiss()
            }
        }
    }

    private func saveZillow() {
        let raw = zillowText.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty {
            model.setZillow("", for: listing.id)     // clears the link
            zillowError = nil
            playerRefresh = UUID()                     // Zillow is baked into the preview HTML
            Haptics.selection()
            return
        }
        guard let normalized = Self.validZillowURL(raw) else {
            zillowError = "Enter a zillow.com link or a full https:// address."
            return
        }
        zillowError = nil
        zillowText = normalized
        model.setZillow(normalized, for: listing.id)
        playerRefresh = UUID()
        Haptics.selection()
    }

    /// A zillow.com link (any scheme) or any well-formed https URL; nil otherwise.
    static func validZillowURL(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.contains(" ") else { return nil }
        let lower = t.lowercased()
        let withScheme = (lower.hasPrefix("http://") || lower.hasPrefix("https://")) ? t : "https://\(t)"
        guard let url = URL(string: withScheme),
              let host = url.host?.lowercased(), host.contains(".") else { return nil }
        let isZillow = host == "zillow.com" || host.hasSuffix(".zillow.com")
        guard isZillow || url.scheme?.lowercased() == "https" else { return nil }
        return withScheme
    }

    /// Room tags edited after publish reach the hosted tour (F-A-10): rescale
    /// to the rendered timeline exactly like `AppModel.publishTour` and PATCH
    /// the chapters. Best effort — a small status line says what happened.
    ///
    /// AI SUGGESTIONS NOBODY CONFIRMED ARE NOT PART OF THIS. `RoomTaggerView`
    /// already deletes them on its way out, so in practice none survive to be
    /// seen here — but SwiftUI does not promise that a sheet's `onDisappear`
    /// runs before this `onDismiss`, and "did an unread AI room name get
    /// published to the buyer-facing tour?" must not depend on that order. So
    /// both sides of the comparison, and the chapters themselves, are taken
    /// from the human-confirmed tags only: an auto-filled tagger opened and
    /// closed without a glance is then not a change, and writes nothing at all.
    private func roomTaggerDismissed() {
        guard hasCurrentRoomTagContext, let source = roomTagAsset else { return }
        playerRefresh = UUID()
        let l = currentListing
        guard !l.isSample, let renderID = l.publishedRenderID, tour != nil else { return }
        let tags = source.roomTags.filter { !$0.isFromAI }
        guard tags != tagsBeforeEdit.filter({ !$0.isFromAI }) else { return }
        let sf = safeSpeedFactor
        let chapters: [ChapterInput] = tags
            .sorted { $0.tMs < $1.tMs }
            .enumerated()
            .map { idx, tag in
                ChapterInput(label: tag.name, tMs: Int((Double(tag.tMs) / sf).rounded()), sort: idx)
            }
        chapterSyncNote = "Updating chapters on your share link…"
        let api = model.api
        let expectedScope = presentationScope
        Task {
            guard expectedScope == presentationScope, hasCurrentRoomTagContext,
                  roomTagAsset?.id == source.id else { return }
            do {
                try await api.updateChapters(renderID: renderID, chapters: chapters)
                guard expectedScope == presentationScope, hasCurrentRoomTagContext,
                      roomTagAsset?.id == source.id else { return }
                chapterSyncNote = "Chapters updated on your share link."
            } catch {
                guard expectedScope == presentationScope, hasCurrentRoomTagContext,
                      roomTagAsset?.id == source.id else { return }
                let why = AIFailure(error).message
                chapterSyncNote = "Couldn't update the chapters on your share link — \(why)"
            }
        }
    }

    /// Forward-geocode the address once per screen visit, storing the coarse
    /// coordinate AND the city/state region label (the aerial generator's
    /// scenery hint — never the street). If only the region is missing, reverse-
    /// geocode the cached fix. The geocoder is retained in @State so the
    /// callback can't be dropped (F-A-26); one attempt per appearance is the
    /// back-off.
    private func geocodeIfNeeded() {
        let l = currentListing
        guard !l.isSample, !geocodeAttempted else { return }
        let addr = l.address.trimmingCharacters(in: .whitespaces)
        guard !addr.isEmpty else { return }
        let hasRegion = !(l.regionLabel ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        if l.hasCoordinate && hasRegion { return }
        geocodeAttempted = true
        let id = l.id

        if l.hasCoordinate, let lat = l.latitude, let lon = l.longitude, lat.isFinite, lon.isFinite {
            geocoder.reverseGeocodeLocation(CLLocation(latitude: lat, longitude: lon)) { marks, _ in
                let mark = marks?.first
                guard let region = Self.regionLabel(from: mark) else { return }
                let state = Self.stateCode(from: mark)
                DispatchQueue.main.async { model.setRegion(region, stateCode: state, for: id) }
            }
            return
        }
        geocoder.geocodeAddressString(addr) { marks, _ in
            guard let mark = marks?.first else { return }
            let coord = mark.location?.coordinate
            let region = Self.regionLabel(from: mark)
            let state = Self.stateCode(from: mark)
            DispatchQueue.main.async {
                if let c = coord, c.latitude.isFinite, c.longitude.isFinite {
                    // Coarsen before it ever touches the model — the same
                    // precision the API accepts (2026-09 audit P0-6 follow-up).
                    model.setCoordinate(lat: coarseCoordinate(c.latitude),
                                        lon: coarseCoordinate(c.longitude), for: id)
                }
                if let region { model.setRegion(region, stateCode: state, for: id) }
            }
        }
    }

    /// "Charlotte, NC" from a placemark — locality + administrative area only.
    /// The street never appears here, so the label is safe to send to the AI.
    static func regionLabel(from mark: CLPlacemark?) -> String? {
        guard let mark else { return nil }
        let city = (mark.locality ?? mark.subAdministrativeArea ?? "").trimmingCharacters(in: .whitespaces)
        let state = (mark.administrativeArea ?? "").trimmingCharacters(in: .whitespaces)
        var parts: [String] = []
        if !city.isEmpty { parts.append(city) }
        if !state.isEmpty, state != city { parts.append(state) }
        if parts.isEmpty, let country = mark.country?.trimmingCharacters(in: .whitespaces), !country.isEmpty {
            parts.append(country)
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// The placemark's administrative area ("CA", "NC") — what the California
    /// AB 723 banner keys off. Never the street; a state is not a location fix.
    static func stateCode(from mark: CLPlacemark?) -> String? {
        guard let raw = mark?.administrativeArea?.trimmingCharacters(in: .whitespaces),
              !raw.isEmpty else { return nil }
        return raw
    }

    private func statCard(_ value: String, _ label: String, _ icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(Theme.accent)
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.rpCaption)
                .foregroundStyle(Theme.inkDim)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Theme.fillSubtle, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

/// Which of the two share links a QR sheet is being built for. Identifiable so
/// one `.sheet(item:)` covers both without a second boolean (and so the sheet
/// can never open on the wrong link).
private struct QRTarget: Identifiable {
    let id = UUID()
    let url: URL
    /// "Your link" / "MLS link — unbranded" — shown as the sheet's title.
    let linkName: String
    /// One line under the code saying where this QR belongs.
    let caption: String
}

/// A built compliance CSV waiting for the share sheet.
private struct AuditExport: Identifiable {
    let id = UUID()
    let url: URL
}

/// A single map annotation for the listing's geocoded location. The id is
/// derived from the coordinate so the marker doesn't get a new identity (and
/// re-animate) on every body evaluation.
struct MapPin: Identifiable {
    let coordinate: CLLocationCoordinate2D
    var id: String { "\(coordinate.latitude),\(coordinate.longitude)" }
}

// MARK: - Shared helpers for this screen's tools
// All file-private: they exist for the views in this file only, so other files
// can't collide with (or depend on) them.

/// A failure the AI/publish sheets can act on (decision A12): the server's own
/// message when there is one, plus the status class so the UI can offer the
/// right next step — "Upgrade plan" on 402, "Retry connection" on 401, "try again in a
/// few minutes" on 429.
struct AIFailure: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let isQuota: Bool
    let isUnauthorized: Bool
    let isRateLimited: Bool
    let isServiceUnavailable: Bool
    let isTrialCapacityUnavailable: Bool

    // No `pricingURL` here any more. A 402 on this screen offers the in-app
    // paywall and nothing else — see `Config.pricingURL` (retired, always nil).

    init(_ error: Error, title: String = "That one didn't work") {
        self.title = title
        if let api = error as? APIError {
            var text = ""
            if case .server(_, _, let m) = api { text = m.trimmingCharacters(in: .whitespacesAndNewlines) }
            if text.isEmpty { text = (api.errorDescription ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
            if text.isEmpty { text = "Something went wrong. Please try again." }
            message = api.isUnauthorized
                ? "The connection to your workspace needs to be restored. Your work is still here."
                : AIFailure.humanReadable(text)
            isQuota = api.isQuota
            isUnauthorized = api.isUnauthorized
            isRateLimited = api.isRateLimited
            isServiceUnavailable = api.isServiceUnavailable
            isTrialCapacityUnavailable = api.isTrialCapacityUnavailable
        } else if AIFailure.isOffline(error) {
            message = "You're offline — check your connection and try again."
            isQuota = false
            isUnauthorized = false
            isRateLimited = false
            isServiceUnavailable = false
            isTrialCapacityUnavailable = false
        } else {
            let text = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            message = text.isEmpty ? "Something went wrong. Please try again." : text
            isQuota = false
            isUnauthorized = false
            isRateLimited = false
            isServiceUnavailable = false
            isTrialCapacityUnavailable = false
        }
    }

    init(message: String, title: String = "That one didn't work") {
        self.title = title
        self.message = message
        isQuota = false
        isUnauthorized = false
        isRateLimited = false
        isServiceUnavailable = false
        isTrialCapacityUnavailable = false
    }

    /// Re-word a failure WITHOUT losing what class of failure it is.
    ///
    /// A batch of seventeen declutters that stops on a 402 has to say "9 of 17
    /// changed" AND still offer Upgrade plan — `init(message:)` would drop
    /// `isQuota` and leave the alert with an OK button and no way forward, which
    /// is the worst of both. Copies the recovery flags verbatim; only the words
    /// change.
    init(_ other: AIFailure, title: String? = nil, message: String) {
        self.title = title ?? other.title
        self.message = message
        isQuota = other.isQuota
        isUnauthorized = other.isUnauthorized
        isRateLimited = other.isRateLimited
        isServiceUnavailable = other.isServiceUnavailable
        isTrialCapacityUnavailable = other.isTrialCapacityUnavailable
    }

    /// Server messages are written for a person and are shown verbatim —
    /// unless the server forwarded a PROVIDER'S message, which is not.
    ///
    /// An agent was shown this, in an alert, on top of their listing:
    ///
    ///     fal HTTP 422: {"detail":[{"type":"missing","loc":["body","mask_url"],
    ///     "msg":"Field required","input":{"prompt":"Remove all clutter...
    ///
    /// The route behind it is fixed, but the leak is the general problem: any
    /// provider, any day, can hand us a stack trace and this alert will print
    /// it. So anything that reads as machine output is replaced here with plain
    /// words. The original still reaches the log, where it belongs — this
    /// changes what the AGENT sees, never what we can debug from.
    ///
    /// Deliberately conservative: it only fires on shapes no human sentence
    /// has (a JSON body, a bracketed key path, an "HTTP <code>:" prefix), so a
    /// real server sentence — "Pick the photos for your reel first" — is
    /// untouched.
    static func humanReadable(_ text: String) -> String {
        let looksMachine =
            text.contains("{\"") || text.contains("[{") ||
            text.range(of: #"HTTP \d{3}"#, options: .regularExpression) != nil ||
            text.contains("\"detail\"") || text.contains("Traceback")
        guard looksMachine else { return text }
        return "The AI service refused that request. Nothing was charged for it \u{2014} try again, "
             + "and if it keeps happening tell us which change you picked."
    }

    /// Transport failures that mean "no network", not "the server said no".
    static func isOffline(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        let offlineCodes: [URLError.Code] = [
            .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
            .timedOut, .dnsLookupFailed, .cannotFindHost, .internationalRoamingOff,
        ]
        return offlineCodes.contains(urlError.code)
    }

    /// A lost or unreadable answer is not evidence that a paid request failed.
    /// Stop unsent photos and reconcile the retained operation, never rebuy it.
    static func requiresSavedPhotoCheck(_ error: Error) -> Bool {
        if error is URLError { return true }
        guard let api = error as? APIError else { return false }
        if ["photo_quality_pending", "photo_quality_hold"].contains(api.code ?? "") { return true }
        guard let status = api.status else { return true }
        return status == 408 || status >= 500
    }

    /// One-line next step for the status class (empty when there is none).
    var actionHint: String {
        if isTrialCapacityUnavailable { return "Try again later, or contact support. Your saved work is still here." }
        if isQuota { return "A plan upgrade unlocks this. Your saved work is still here." }
        if isUnauthorized { return "The connection to your workspace needs to be restored. Your work is still here." }
        if isRateLimited { return "Try again in a few minutes." }
        if isServiceUnavailable { return "If it keeps happening, contact support — the message above helps us find it." }
        return ""
    }

    /// Message + hint, for alerts that can't lay out a card.
    var fullMessage: String {
        actionHint.isEmpty ? message : "\(message)\n\n\(actionHint)"
    }
}

/// Loud, unmissable failure card with the right next step: the server's message,
/// Upgrade plan on 402, reconnect on 401, wait on 429, otherwise the caller's
/// retry hint. A failed connection never opens Apple registration.
private struct AIFailureCard: View {
    let failure: AIFailure
    var retryHint: String = "Adjust the settings and try again."
    /// Which monthly allowance ran out, for the paywall's one context line.
    /// A `plan_entitlements` key — renders | photo_edits | reels | aerials |
    /// drone. Empty = the generic "monthly allowance" wording.
    var quotaFeature: String = ""
    var onReconnect: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(failure.title, systemImage: "exclamationmark.triangle.fill")
                .font(.rpHeadline)
                .foregroundStyle(Theme.warn)
            Text(failure.message)
                .font(.rpCaption)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            if failure.isQuota {
                Text(failure.actionHint)
                    .font(.rpCaption)
                    .foregroundStyle(Theme.inkDim)
                // In-app purchase, and ONLY in-app purchase: StoreKit 2
                // subscriptions work on every storefront
                // (Purchases/PaywallView.swift). No web pricing link beside it
                // — 3.1.1 / 3.1.3.
                Button {
                    PaywallRouter.shared.present(reason: .quota(feature: quotaFeature))
                } label: {
                    Label("Upgrade plan", systemImage: "arrow.up.circle")
                        .font(.rpBody.weight(.semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .modifier(RendpropActionLabelSurface(primary: true))
                }
            } else if failure.isUnauthorized {
                Text(failure.actionHint)
                    .font(.rpCaption)
                    .foregroundStyle(Theme.inkDim)
                Button { onReconnect() } label: {
                    Label("Retry connection", systemImage: "arrow.clockwise")
                        .font(.rpBody.weight(.semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .modifier(RendpropActionLabelSurface(primary: false))
                }
            } else if failure.isRateLimited {
                Text(failure.actionHint)
                    .font(.rpCaption)
                    .foregroundStyle(Theme.inkDim)
            } else if failure.isServiceUnavailable || failure.isTrialCapacityUnavailable {
                Text(failure.actionHint)
                    .font(.rpCaption)
                    .foregroundStyle(Theme.inkDim)
                Link(destination: SettingsView.supportMailURL(subject: "AI request failed — \(failure.title)")) {
                    Label("Contact support", systemImage: "envelope")
                        .font(.rpBody.weight(.semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .modifier(RendpropActionLabelSurface(primary: false))
                }
            } else {
                Text(retryHint)
                    .font(.rpCaption)
                    .foregroundStyle(Theme.inkDim)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.warn.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Image prep for the AI routes. Every decode / downscale / JPEG encode / base64
/// runs OFF the main actor (`Task.detached`) so a 12 MP photo never stalls the
/// UI (F-A-19). The renderer is pinned to scale 1 so "1280 px" means 1280
/// pixels — the default format inherits the screen's 3× scale and silently
/// tripled every upload.
enum AIImagePrep {
    static func error(_ message: String) -> NSError {
        NSError(domain: "AIImagePrep", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Downscale to `maxDimension` on the long edge; orientation is baked in.
    /// Plain enum member → nonisolated; safe to call from any queue.
    static func downscaled(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > 0, longest.isFinite else { return image }
        let scale = min(1, maxDimension / longest)
        let size = CGSize(width: floor(image.size.width * scale), height: floor(image.size.height * scale))
        guard size.width >= 1, size.height >= 1 else { return image }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// Camera conditioning uses the complete selected photograph. Delivery
    /// format is applied only after raw provider frames pass the quality check.
    /// `downscaled` below bakes orientation without cropping or inventing pixels.
    static func reelSource(_ image: UIImage, aspect: String) -> UIImage { image }

    /// The photo at `url` → downscaled JPEG → base64 (no data: prefix), off main.
    static func jpegBase64(at url: URL, maxDimension: CGFloat, quality: CGFloat, maxBytes: Int? = nil) async -> String? {
        await Task.detached(priority: .userInitiated) { () -> String? in
            guard let ui = UIImage(contentsOfFile: url.path) else { return nil }
            guard let maxBytes else {
                return AIImagePrep.downscaled(ui, maxDimension: maxDimension)
                    .jpegData(compressionQuality: quality)?.base64EncodedString()
            }
            // Only the AI request copy is conditioned. The complete original
            // file and every saved/exported version remain untouched.
            guard maxBytes > 0 else { return nil }
            for scale: CGFloat in [1, 0.875, 0.75, 0.625, 0.5] {
                let image = AIImagePrep.downscaled(ui, maxDimension: maxDimension * scale)
                for candidate: CGFloat in [quality, min(quality, 0.85), min(quality, 0.8)] {
                    if let jpeg = image.jpegData(compressionQuality: candidate), jpeg.count <= maxBytes {
                        return jpeg.base64EncodedString()
                    }
                }
            }
            return nil
        }.value
    }

    /// Decode an AI result (base64 image) and write it as a JPEG, off main.
    /// Returns false when the payload isn't an image or the write fails.
    static func writeJPEG(base64: String, to url: URL, quality: CGFloat) async -> Bool {
        await Task.detached(priority: .userInitiated) { () -> Bool in
            guard let data = Data(base64Encoded: base64),
                  let img = UIImage(data: data),
                  let jpeg = img.jpegData(compressionQuality: quality) else { return false }
            do {
                try jpeg.write(to: url, options: .atomic)
                return true
            } catch {
                return false
            }
        }.value
    }

    /// Write `image` as a JPEG (downscaled to `maxDimension`) at `url`, off main.
    static func writeJPEG(_ image: UIImage, to url: URL, maxDimension: CGFloat, quality: CGFloat) async -> Bool {
        await Task.detached(priority: .userInitiated) { () -> Bool in
            guard let jpeg = AIImagePrep.downscaled(image, maxDimension: maxDimension)
                    .jpegData(compressionQuality: quality) else { return false }
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try jpeg.write(to: url, options: .atomic)
                return true
            } catch {
                return false
            }
        }.value
    }

    /// A fully-decoded image ≤ `maxPixel` on the long edge via ImageIO — for the
    /// full-screen viewer, where a lazily-decoded full-res UIImage would decode
    /// on the main thread at first draw.
    static func decoded(at url: URL, maxPixel: Int) async -> UIImage? {
        await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
            return UIImage(cgImage: cg)
        }.value
    }
}

/// A grid/card thumbnail that never decodes a full-res JPEG inside `body`:
/// ImageIO thumbnail (≤ 800 px) via the shared `ImageThumbnails` cache, loaded
/// in `.task` and memoized by path + modification date.
private struct DetailPhotoThumb: View {
    let url: URL
    var height: CGFloat = 150
    @State private var image: UIImage?

    var body: some View {
        // The image is an OVERLAY on a fixed-height, column-wide base, not the
        // layout view itself: a resizable `scaledToFill` image reports its own
        // ideal width (a landscape photo at 150 pt tall wants ~270 pt), and a
        // `.frame(maxWidth: .infinity)` around it does not cap that, so the
        // LazyVGrid cell grew to the photo and the grid spilled off the screen
        // (seen on the 6 Sep store captures with 16:9 photos). An overlay is
        // sized to the base and `.clipped()` trims the fill.
        Color.clear
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Rectangle().fill(Theme.fillSubtle)
                }
            }
            .clipped()
        .task(id: url) {
            if let hit = ImageThumbnails.cached(url) {
                image = hit
                return
            }
            image = await ImageThumbnails.load(url)
        }
    }
}

private struct ListingFactsReviewCard: View {
    let review: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Listing details need review", systemImage: "arrow.triangle.2.circlepath")
                .font(.rpHeadline)
            Text("Your edits are saved on this iPhone. Compare them with the shared listing before syncing.")
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
            Button("Review shared listing details", action: review)
                .font(.rpBody.weight(.semibold))
                .accessibilityIdentifier("listing.factsReview")
        }.frame(maxWidth: .infinity, alignment: .leading).padding()
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius))
    }
}

/// Phone-editable facts only. Private measurement state and server-managed
/// attachments cannot become part of an ordinary replacement approval.
private enum ListingFactsReviewRows {
    struct Row: Identifiable {
        let id: String
        let title: String
        let local: String
        let shared: String
    }

    static func make(_ review: ListingFactsReview) -> [Row] {
        let a = review.local, b = review.shared
        func text(_ value: String?) -> String {
            let cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return cleaned.isEmpty ? "Not set" : cleaned
        }
        func location(_ listing: Listing) -> String {
            guard let lat = listing.latitude, let lon = listing.longitude,
                  lat.isFinite, lon.isFinite else { return "Not set" }
            return String(format: "%.3f, %.3f", lat, lon)
        }
        func sold(_ listing: Listing) -> String {
            guard let date = listing.soldAt else { return "Active" }
            return "Sold · " + ISO8601DateFormatter().string(from: date).prefix(10)
        }
        var rows: [Row] = [
            .init(id: "address", title: "Address", local: a.address, shared: b.address),
            .init(id: "beds", title: "Beds", local: a.beds > 0 ? String(a.beds) : "Not set", shared: b.beds > 0 ? String(b.beds) : "Not set"),
            .init(id: "baths", title: "Baths", local: a.baths > 0 ? String(a.baths) : "Not set", shared: b.baths > 0 ? String(b.baths) : "Not set"),
            .init(id: "sqft", title: "Square feet", local: a.sqft > 0 ? String(a.sqft) : "Not set", shared: b.sqft > 0 ? String(b.sqft) : "Not set"),
            .init(id: "price", title: "Price", local: a.price.cents > 0 ? a.price.formatted : "Not set", shared: b.price.cents > 0 ? b.price.formatted : "Not set"),
            .init(id: "tagline", title: "Description", local: text(a.tagline), shared: text(b.tagline)),
            .init(id: "location", title: "Location", local: location(a), shared: location(b)),
            .init(id: "sold", title: "Listing status", local: sold(a), shared: sold(b)),
            .init(id: "zillow", title: "Zillow link", local: text(a.zillowURL), shared: text(b.zillowURL)),
        ]
        let localDetails = ListingFactsSync.detailValues(a), sharedDetails = ListingFactsSync.detailValues(b)
        let labels = Dictionary(SpaceType.allCases.flatMap { $0.detailFields }.map { ($0.key, $0.label) }, uniquingKeysWith: { first, _ in first })
        for key in Set(localDetails.keys).union(sharedDetails.keys).sorted() {
            let title = key == Listing.searchIndexingKey ? "List on Google" : labels[key] ?? key
            rows.append(.init(id: "detail:" + key, title: title,
                              local: text(localDetails[key]), shared: text(sharedDetails[key])))
        }
        return rows
    }
}

private struct ListingFactsComparisonRow: View {
    let row: ListingFactsReviewRows.Row

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(row.title).font(.rpBody.weight(.semibold))
            VStack(alignment: .leading, spacing: 4) {
                Text("On this iPhone").font(.rpCaption).foregroundStyle(Theme.inkDim)
                Text(row.local).font(.rpBody).textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Shared details").font(.rpCaption).foregroundStyle(Theme.inkDim)
                Text(row.shared).font(.rpBody).textSelection(.enabled)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ListingFactsReviewSheet: View {
    let listingID: UUID
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var auth = AuthStore.shared
    @State private var review: ListingFactsReview?
    @State private var loading = false
    @State private var error: String?

    private var reviewIsCurrent: Bool {
        guard let review else { return false }
        return auth.isIdentified && auth.userID == review.ownerID
            && auth.syncSessionRevision == review.sessionRevision
            && WorkspaceContext.selectedOrgID == review.local.serverOrgID
            && model.listings.first(where: { $0.id == listingID }) == review.local
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Compare the details saved on this iPhone with the current shared listing.")
                    if let review {
                        Text(review.local.factsSync?.hasChanges == true && review.local.factsSync?.reviewRequired != true
                             ? "Keep my edits retries only the fields you changed."
                             : "Keep my edits approves the iPhone details shown below for syncing.")
                            .font(.rpCaption).foregroundStyle(Theme.inkDim)
                    }
                    if loading { ProgressView("Loading shared details…") }
                    if let error { Text(error).font(.rpCaption).foregroundStyle(.red) }
                    if review != nil && !reviewIsCurrent && error == nil {
                        Text("The listing, account or workspace changed. Reload the comparison before choosing.")
                            .font(.rpCaption).foregroundStyle(.orange)
                    }
                    Button("Reload comparison") { Task { await load() } }
                        .disabled(loading).accessibilityIdentifier("listing.factsReview.reload")
                }
                if let review {
                    Section("Listing details") {
                        ForEach(ListingFactsReviewRows.make(review)) { row in
                            ListingFactsComparisonRow(row: row)
                        }
                    }
                    Section {
                        Button("Use shared details") { resolve(keepLocal: false) }
                            .accessibilityIdentifier("listing.factsReview.useShared")
                        Button("Keep my edits") { resolve(keepLocal: true) }
                            .accessibilityIdentifier("listing.factsReview.keepLocal")
                    }.disabled(loading || !reviewIsCurrent || error != nil)
                }
            }
            .navigationTitle("Review listing details").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task { await load() }
            .onChange(of: auth.userID) { _ in review = nil; error = "Your account changed. Reopen the listing to review its details." }
            .onReceive(NotificationCenter.default.publisher(for: .rendpropWorkspaceChanged)) { _ in
                review = nil; error = "Your workspace changed. Reopen the listing to review its details."
            }
        }
    }

    @MainActor private func load() async {
        guard !loading else { return }
        loading = true; error = nil; review = nil
        defer { loading = false }
        do { review = try await model.loadListingFactsReview(listingID) }
        catch { self.error = error.localizedDescription }
    }

    @MainActor private func resolve(keepLocal: Bool) {
        guard let review, reviewIsCurrent else { return }
        do {
            try model.resolveListingFacts(review, keepLocal: keepLocal)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

/// Captures an export's session without treating ordinary JWT rotation as an
/// account change. Admission is checked before Photos begins its transaction;
/// iOS may finish a transaction that has already begun.
@MainActor private struct NativeMediaExportContext {
    private let owner = AuthStore.shared.userID
    private let revision = AuthStore.shared.syncSessionRevision
    private let workspace = WorkspaceContext.selectedOrgID

    var isCurrent: Bool {
        !Task.isCancelled && AuthStore.shared.userID == owner
            && AuthStore.shared.syncSessionRevision == revision
            && WorkspaceContext.selectedOrgID == workspace
    }
}

/// Photos-library saves with a REAL completion (F-A-16). Both calls throw on a
/// denied permission or a failed write, so a caller flips "Saved to Photos"
/// only when the asset actually landed.
private enum PhotosLibrarySaver {
    struct Denied: LocalizedError {
        var errorDescription: String? {
            "Rendprop isn't allowed to add to your Photos. Allow it in Settings → Rendprop → Photos, then try again."
        }
    }
    struct ContextChanged: LocalizedError {
        var errorDescription: String? { "Your account, workspace or listing changed. Reopen it before exporting." }
    }

    @MainActor static func saveVideo(at url: URL, while canSave: @escaping @MainActor () -> Bool = { true }) async throws {
        let context = NativeMediaExportContext()
        guard context.isCurrent, canSave() else { throw ContextChanged() }
        try await ensureAddAccess()
        guard context.isCurrent, canSave() else { throw ContextChanged() }
        try await PHPhotoLibrary.shared().performChanges {
            _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }

    @MainActor static func saveImage(_ image: UIImage, while canSave: @escaping @MainActor () -> Bool = { true }) async throws {
        try await ensureAddAccess()
        guard !Task.isCancelled, canSave() else { throw ContextChanged() }
        try await PHPhotoLibrary.shared().performChanges {
            _ = PHAssetChangeRequest.creationRequestForAsset(from: image)
        }
    }

    /// Save an image FILE as-is — no decode, no re-encode. Used for compliance
    /// originals (W2-C2): a re-encoded "original" is not the original, and a
    /// broker who asks for the unaltered image is entitled to the exact bytes
    /// the public "View original" link serves.
    @MainActor static func saveImageFile(at url: URL, while canSave: @escaping @MainActor () -> Bool = { true }) async throws {
        let context = NativeMediaExportContext()
        guard context.isCurrent, canSave() else { throw ContextChanged() }
        try PhotoVersionHistory.requireDownloadReview(imageURL: url)
        try await ensureAddAccess()
        guard context.isCurrent, canSave() else { throw ContextChanged() }
        try PhotoVersionHistory.requireDownloadReview(imageURL: url)
        try await PHPhotoLibrary.shared().performChanges {
            _ = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
        }
    }

    private static func ensureAddAccess() async throws {
        var status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        }
        guard status == .authorized || status == .limited else { throw Denied() }
    }
}

/// Real QR code for the hosted link (F-A-15): `CIFilter.qrCodeGenerator`
/// rendered at 1024 px with Save image / Share.
private struct QRShareSheet: View {
    let url: URL
    let title: String
    /// Which link this code opens — "Your link" / "MLS link — unbranded".
    /// The user must never be in doubt about which one they just printed.
    var linkName: String = "Tour link"
    /// One line under the code saying where this QR belongs.
    var caption: String = "Scan to open the tour — print it on a flyer, sign-in sheet or yard sign."
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var failed = false
    @State private var saved = false
    @State private var isSaving = false
    @State private var saveError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if let image {
                        Image(uiImage: image)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 280)
                            .padding(12)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .accessibilityLabel(Text("QR code that opens \(url.absoluteString)"))
                    } else if failed {
                        Text("Couldn't build the QR code.")
                            .font(.rpBody).foregroundStyle(Theme.warn)
                            .frame(height: 200)
                    } else {
                        ProgressView().frame(height: 200)
                    }

                    Text(url.absoluteString)
                        .font(.rpCaption)
                        .foregroundStyle(Theme.inkDim)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                    Text(caption)
                        .font(.rpCaption)
                        .foregroundStyle(Theme.inkDim)
                        .multilineTextAlignment(.center)

                    if let image {
                        Button { save(image) } label: {
                            Label(saved ? "Saved to Photos" : "Save image",
                                  systemImage: saved ? "checkmark.circle.fill" : "square.and.arrow.down")
                                .font(.rpBody.weight(.semibold))
                                .frame(maxWidth: .infinity).padding(.vertical, 14)
                                .modifier(RendpropActionLabelSurface(primary: true))
                        }
                        .disabled(saved || isSaving)

                        ShareLink(item: Image(uiImage: image),
                                  preview: SharePreview("\(linkName) QR — \(title)", image: Image(uiImage: image))) {
                            Label("Share QR code", systemImage: "square.and.arrow.up")
                                .font(.rpBody.weight(.semibold))
                                .frame(maxWidth: .infinity).padding(.vertical, 13)
                                .modifier(RendpropActionLabelSurface(primary: false))
                        }
                    }
                    if let saveError {
                        Text(saveError)
                            .font(.rpCaption)
                            .foregroundStyle(Theme.warn)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding()
            }
            .background(Theme.bg)
            .navigationTitle(linkName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                let made = await QRCodeMaker.make(url.absoluteString, size: 1024)
                image = made
                failed = made == nil
            }
        }
        .presentationDetents([.large])
    }

    private func save(_ image: UIImage) {
        isSaving = true
        saveError = nil
        Task {
            do {
                try await PhotosLibrarySaver.saveImage(image)
                await MainActor.run {
                    isSaving = false
                    saved = true
                    Haptics.success()
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    saveError = error.localizedDescription
                }
            }
        }
    }
}

private enum QRCodeMaker {
    /// A crisp QR image `size` px square (nearest-neighbour scale of the
    /// generator's module grid), built off the main actor.
    static func make(_ text: String, size: CGFloat) async -> UIImage? {
        await Task.detached(priority: .userInitiated) { () -> UIImage? in
            let filter = CIFilter.qrCodeGenerator()
            filter.message = Data(text.utf8)
            filter.correctionLevel = "M"
            guard let output = filter.outputImage, output.extent.width > 0 else { return nil }
            let scale = size / output.extent.width
            let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let context = CIContext()
            guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
            return UIImage(cgImage: cg)
        }.value
    }
}

// MARK: - Listing files (one item type for everything a listing produced)

/// One thing a listing has made, whatever kind of thing it is, so the listing
/// screen's FILES section can show reels, the aerial intro, AI photos, motion
/// clips, the floor plan and the rendered tour in one list.
///
/// Deliberately thin — identity, a file URL and a date. Every list it is built
/// from already exists (`ReelStudioView.reelFiles`, `EnhancedPhoto.loadAll`,
/// `PhotoStudioView.SavedClip.loadAll`, `Listing.aerialURL`, `AppModel.tours`)
/// and this type only UNIFIES them for display; it is not a second source of
/// truth about what is on disk.
/// `Sendable` since the build-9 lag report: the scan that builds these runs
/// on a background thread and hands the finished array to the main actor in one
/// hop, and every stored property here is already a value type.
struct ListingMediaItem: Identifiable, Hashable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case tour, reel, aerial, motionClip, photo, floorPlan
    }

    /// Unique within one listing's list — prefixed by kind so a reel file and a
    /// photo id can never collide inside a `ForEach`.
    let id: String
    let kind: Kind
    let url: URL
    /// The untouched "before" beside an AI-edited photo, when there is a separate
    /// one. Nil for every other kind, and nil for a photo that is its own before.
    let originalURL: URL?
    let createdAt: Date
    /// Local publication choice, resolved by the background file scan. Separate
    /// from saved-to-Photos state and from completed cloud publication.
    var selectedForListing = false
    var publicationLabel: String? = nil

    /// True when opening this plays something rather than showing it.
    var isVideo: Bool {
        switch kind {
        case .tour, .reel, .aerial, .motionClip: return true
        case .photo, .floorPlan:                 return false
        }
    }

    /// What this file is called, in the words the agent would use.
    ///
    /// "Motion clip" and "Aerial intro" were OUR words for it — a feature name
    /// and a pipeline stage. A person who made one of these an hour ago and is
    /// now looking for it is thinking "the moving photo" and "the flyover", and
    /// the possessive matters more than it looks: the complaint that started this
    /// section was "I don't have any of the photos or videos I made saved", and
    /// "Your video" covers both listing and social-media deliveries.
    var title: String {
        switch kind {
        case .tour:       return "Your walkthrough tour"
        case .reel:       return "Your video"
        case .aerial:     return "Your flyover opening"
        case .motionClip: return "Moving photo"
        case .photo:      return "Your photo"
        case .floorPlan:  return "Your floor plan"
        }
    }

    /// One plain line saying what this file is FOR — the agent should not have to
    /// remember which studio made which file, and "what do I do with it" is the
    /// question a file list actually has to answer.
    var blurb: String {
        switch kind {
        case .tour:       return "The tour people scroll through"
        case .reel:       return "Watch, save or share your finished video"
        case .aerial:     return "The flyover that opens your video"
        case .motionClip: return "One photo, turned into video"
        case .photo:      return "Edited in AI Photo Studio"
        case .floorPlan:  return "A 3D scan you can spin around"
        }
    }

    /// A 3D scan is not a Photos asset, so the only honest action for one is
    /// Share. Everything else goes to the camera roll, and the button says so.
    var savesToPhotos: Bool { kind != .floorPlan }

    var icon: String {
        switch kind {
        case .tour:       return "play.rectangle.fill"
        case .reel:       return "film.stack"
        case .aerial:     return "airplane.departure"
        case .motionClip: return "play.rectangle.on.rectangle"
        case .photo:      return "photo"
        case .floorPlan:  return "cube.transparent"
        }
    }

    /// The feature's signature gradient — the same one the tool wears in the
    /// TOOLBOX grid and on Home, so a file is recognisably from that tool.
    ///
    /// A plain computed property on a plain struct: `RPGradient` is not isolated,
    /// and neither is this, so a non-isolated thumbnail view can read it.
    var gradient: LinearGradient {
        switch kind {
        case .tour, .reel, .motionClip: return RPGradient.reel
        case .aerial:                   return RPGradient.aerial
        case .photo:                    return RPGradient.photo
        case .floorPlan:                return RPGradient.plan
        }
    }

    /// "Made 4 Sep at 2:15 PM", or a neutral line when the filesystem has no
    /// creation date — same wording as `ReelStudioView.reelDateLabel`.
    var dateLabel: String {
        guard createdAt != .distantPast else { return "Saved on this phone" }
        return "Made \(createdAt.formatted(date: .abbreviated, time: .shortened))"
    }
}

/// One directory entry plus the ONE attribute this screen sorts on, read once.
///
/// THE BUILD-9 LAG REPORT, in the owner's words: "laggy as hell — that will kill
/// the business". The cause was mine. Every list on this screen used to read a
/// file's creation date with `url.resourceValues(forKeys:)` INSIDE its sort
/// comparator, so a folder of n files cost O(n log n) stat syscalls to sort and
/// then another n to build the rows — and all of it ran on the main actor before
/// the screen could draw. Reading the date once, into a value, and sorting on
/// that value is the whole fix; `DiskScan.entries` is the only place that reads
/// it. `Sendable` because a finished scan crosses back to the main actor.
private struct DatedFile: Sendable {
    let url: URL
    /// `lastPathComponent`, kept so a filter or a tie-break never re-derives it.
    let name: String
    let createdAt: Date
}

/// An `EnhancedPhoto` carrying the creation date the directory read already
/// produced. A named type rather than a tuple so `EnhancedPhoto.loadAll` can
/// keep returning plain `[EnhancedPhoto]` for its four existing callers while
/// the listing screen's FILES scan gets the date for free.
private struct DatedPhoto {
    let photo: EnhancedPhoto
    let createdAt: Date
}

/// The listing screen's directory reads, in one nonisolated place.
///
/// NONISOLATED ON PURPOSE, and file-scope rather than nested inside any `View`:
/// the whole point of this type is that it can be called from a background task.
/// A `@MainActor` static reached from a non-isolated context is the exact bug
/// class the Mac build caught once already (`GearStore.normalizedASIN`), and a
/// helper that lives inside a `View` is isolated whether or not anybody meant it
/// to be. Nothing in here touches the model, the view, or any global state.
private enum DiskScan {
    /// Every entry in `dir`, with its creation date.
    ///
    /// `includingPropertiesForKeys: [.creationDateKey]` is not decoration: it
    /// makes the filesystem hand the dates back WITH the listing, so the
    /// `resourceValues` read below is served from the values the enumeration
    /// already prefetched onto each URL instead of costing a stat per file.
    /// A missing directory is an empty list, never an error.
    nonisolated static func entries(of dir: URL) -> [DatedFile] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return urls.map { url in
            DatedFile(url: url,
                      name: url.lastPathComponent,
                      createdAt: createdAt(of: url))
        }
    }

    /// A file's creation date, or `.distantPast` when the filesystem has none —
    /// which `ListingMediaItem.dateLabel` prints as "Saved on this phone".
    nonisolated static func createdAt(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
    }

    /// A directory's (or file's) modification date, or nil when it isn't there.
    ///
    /// This is the whole of the "has anything changed?" test. Adding, removing
    /// or renaming an entry bumps its directory's modification date, and every
    /// writer in this app either moves a finished file in or writes it
    /// atomically (which is a rename), so a new reel, photo, clip or plan always
    /// shows up here. Overwriting a file's BYTES in place does not bump it — and
    /// must not: the row's identity, url and creation date are all unchanged,
    /// and the picture itself is the thumbnail cache's problem, not this list's.
    nonisolated static func modifiedAt(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// Newest first, ties broken by name — the order every list on this screen
    /// has always used, now sorting on a date that was read once.
    nonisolated static func newestFirst(_ files: [DatedFile]) -> [DatedFile] {
        files.sorted { a, b in
            a.createdAt != b.createdAt ? a.createdAt > b.createdAt : a.name > b.name
        }
    }

    /// `clip-*.mp4` in a listing's photo folder, newest first, from a directory
    /// listing the caller already has. `PhotoStudioView.SavedClip.loadAll` and
    /// the listing screen's own scan both come through here, so there is one
    /// glob rather than two — and the listing screen reads `Photos/<id>/` ONCE
    /// for the clips AND the photos instead of twice.
    nonisolated static func motionClips(in entries: [DatedFile]) -> [DatedFile] {
        newestFirst(entries.filter {
            $0.name.hasPrefix("clip-") && $0.url.pathExtension.lowercased() == "mp4"
        })
    }
}

extension ListingMediaItem {
    /// Everything a scan needs from the main actor, snapshotted BEFORE it hops
    /// off. Plain values, every one of them.
    ///
    /// This type is the isolation boundary. Build 8 had `loadAll` marked
    /// `@MainActor` precisely because it reached for statics that were isolated,
    /// and that annotation is what put fifty-odd filesystem calls in front of the
    /// first frame. Moving the work off the main actor means the work can no
    /// longer ASK the model or the view for anything, so everything it needs is
    /// copied in here first — including the aerial as its Documents-relative
    /// path rather than as `Listing.aerialURL`, because that property stats the
    /// file and the stat belongs on the scanning thread.
    struct ScanRequest: Sendable, Equatable {
        var listingID: UUID
        var tourURL: URL?
        var aerialRelPath: String?
        var aerialGeneratedAt: Date?
    }

    /// The cheap answer to "is another scan worth running?".
    ///
    /// `onAppear` fires on every push AND every pop back, so walking into AI
    /// Photo Studio and straight back out used to re-read every directory this
    /// listing owns for a list that had not changed by one byte. This is five
    /// modification dates: the four folders a listing's media can appear in, plus
    /// the rendered tour, which lives at a path this screen does not own and is
    /// REWRITTEN AT THE SAME PATH by a re-render. The request itself is part of
    /// the stamp because a new aerial changes the model, not a directory we watch.
    struct ScanStamp: Sendable, Equatable {
        var request: ScanRequest
        var tour: Date?
        var aerial: Date?
        var reels: Date?
        var photos: Date?
        var plans: Date?
    }

    /// A finished scan and the stamp that produced it, moved to the main actor
    /// in ONE hop.
    struct Scan: Sendable {
        var items: [ListingMediaItem]
        var stamp: ScanStamp
    }

    /// Everything this listing has on disk, newest first — read off the main
    /// actor. Nil means "nothing has changed since `previous`, keep what you have".
    ///
    /// `Task.detached` rather than a bare `nonisolated func`: a non-isolated
    /// `async` function's executor is a moving target across language modes and
    /// build settings (Swift 6.2's approachable-concurrency default runs one on
    /// the CALLER's actor), and this call must land on a background thread under
    /// every one of them. It is also the pattern already shipping three feet
    /// further down this file — `AIImagePrep.jpegBase64`, `ImageThumbnails.load`
    /// — so there is one way of getting off the main actor here, not two.
    nonisolated static func scan(_ request: ScanRequest,
                                 since previous: ScanStamp?) async -> Scan? {
        await Task.detached(priority: .userInitiated) {
            ListingMediaItem.scanNow(request, since: previous)
        }.value
    }

    /// The synchronous body of `scan`. Never call this on the main actor.
    nonisolated static func scanNow(_ request: ScanRequest,
                                    since previous: ScanStamp?) -> Scan? {
        let stamp = currentStamp(for: request)
        if let previous, previous == stamp { return nil }
        return Scan(items: scannedItems(for: request), stamp: stamp)
    }

    private nonisolated static var reelsDirectory: URL {
        FileStore.documents.appendingPathComponent("reels", isDirectory: true)
    }

    private nonisolated static var floorPlansDirectory: URL {
        FileStore.documents.appendingPathComponent("FloorPlans", isDirectory: true)
    }

    private nonisolated static func currentStamp(for request: ScanRequest) -> ScanStamp {
        // Written out longhand rather than as one nested expression: this file
        // has hit the type-checker's expression budget before, and a stamp is
        // read on every appearance of the screen.
        var tour: Date?
        if let tourURL = request.tourURL {
            tour = DiskScan.modifiedAt(of: tourURL)
        }
        var aerial: Date?
        if let relPath = request.aerialRelPath {
            aerial = DiskScan.modifiedAt(of: FileStore.url(fromRelativePath: relPath))
        }
        let reels = DiskScan.modifiedAt(of: reelsDirectory)
        let photos = DiskScan.modifiedAt(of: EnhancedPhoto.directory(for: request.listingID))
        let plans = DiskScan.modifiedAt(of: floorPlansDirectory)
        return ScanStamp(request: request, tour: tour, aerial: aerial,
                         reels: reels, photos: photos, plans: plans)
    }

    /// The list itself. Identical in content and order to what build 8 built on
    /// the main actor — same globs, same ids, same newest-first ordering, same
    /// "the aerial's own generated-at beats the file's date" rule. The only
    /// changes are WHERE it runs and how many syscalls it costs.
    private nonisolated static func scannedItems(for request: ScanRequest) -> [ListingMediaItem] {
        let fm = FileManager.default
        var items: [ListingMediaItem] = []

        if let tourURL = request.tourURL, fm.fileExists(atPath: tourURL.path) {
            items.append(ListingMediaItem(id: "tour", kind: .tour, url: tourURL,
                                          originalURL: nil,
                                          createdAt: DiskScan.createdAt(of: tourURL)))
        }
        // EVERY reel, not just the newest — the old "YOUR LAST REEL" card showed
        // one, four screens deep, and pruning quietly ate the rest.
        for reel in ReelStudioView.datedReelFiles(for: request.listingID) {
            items.append(ListingMediaItem(id: "reel-\(reel.name)", kind: .reel,
                                          url: reel.url, originalURL: nil,
                                          createdAt: reel.createdAt))
        }
        // The aerial is attached to the listing and carries its own generated-at
        // date, which is truer than the file's when a restore rewrote the file.
        if let relPath = request.aerialRelPath {
            let aerial = FileStore.url(fromRelativePath: relPath)
            if fm.fileExists(atPath: aerial.path) {
                items.append(ListingMediaItem(id: "aerial-\(aerial.lastPathComponent)",
                                              kind: .aerial, url: aerial, originalURL: nil,
                                              createdAt: request.aerialGeneratedAt
                                                  ?? DiskScan.createdAt(of: aerial)))
            }
        }
        // ONE read of Photos/<listingID>/ for both the motion clips and the
        // photos. Build 8 enumerated that folder twice — once inside
        // `SavedClip.loadAll` and once inside `EnhancedPhoto.loadAll` — and then
        // asked the filesystem whether an `orig-` sibling existed once PER PHOTO.
        // On a twenty-photo listing that alone was twenty-two syscalls for
        // information the first listing already contained.
        let photoDirectory = EnhancedPhoto.directory(for: request.listingID)
        let photoEntries = DiskScan.entries(of: photoDirectory)
        let selectionIndex = try? PhotoVersionHistory.load(directory: photoDirectory)
        for clip in DiskScan.motionClips(in: photoEntries) {
            items.append(ListingMediaItem(id: "clip-\(clip.name)", kind: .motionClip,
                                          url: clip.url, originalURL: nil,
                                          createdAt: clip.createdAt))
        }
        for entry in EnhancedPhoto.dated(in: photoEntries, directory: photoDirectory) {
            let photo = entry.photo
            let separateOriginal = photo.originalURL.standardizedFileURL
                != photo.enhancedURL.standardizedFileURL
            items.append(ListingMediaItem(id: "photo-\(photo.id)", kind: .photo,
                                          url: photo.enhancedURL,
                                          originalURL: separateOriginal ? photo.originalURL : nil,
                                          createdAt: entry.createdAt,
                                          selectedForListing: selectionIndex?.isSelectedForListing(photo.id) == true,
                                          publicationLabel: selectionIndex?.publicationLabel(for: photo.id)))
        }
        let plan = floorPlansDirectory
            .appendingPathComponent("\(request.listingID.uuidString).usdz")
        if fm.fileExists(atPath: plan.path) {
            items.append(ListingMediaItem(id: "plan", kind: .floorPlan, url: plan,
                                          originalURL: nil,
                                          createdAt: DiskScan.createdAt(of: plan)))
        }

        return items.sorted { a, b in
            a.createdAt != b.createdAt ? a.createdAt > b.createdAt : a.id > b.id
        }
    }
}

/// First-frame posters for the FILES rows, memoized in memory. Same
/// `AVAssetImageGenerator` recipe `PosterMaker` uses for the hosted page, at row
/// size. File scope and un-isolated on purpose: it is awaited from a `.task` and
/// must be free to do its work off the main actor.
private enum VideoPosters {
    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 120
        c.totalCostLimit = 24 * 1024 * 1024
        return c
    }()

    /// Keyed by path + MODIFICATION DATE + size, exactly the way
    /// `ImageThumbnails.key` is (`Support/FileStore.swift`) rather than by path
    /// alone. That is not tidiness: the rendered tour is rewritten AT THE SAME
    /// PATH by every re-render, so a path-only key served the PREVIOUS render's
    /// first frame for the rest of the process's life. One `attributesOfItem`
    /// per lookup buys that correctness, and it is the same one stat the photo
    /// rows already pay through `ImageThumbnails.cached`.
    private static func key(_ url: URL, maxPixel: CGFloat) -> NSString {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
            .flatMap { $0 }?.timeIntervalSince1970 ?? 0
        return "\(url.path)|\(Int(mtime))|\(Int(maxPixel))" as NSString
    }

    /// Cached poster if one was already generated (synchronous, main-thread
    /// safe) — the no-flash fast path `MediaThumb` takes before it awaits.
    static func cached(_ url: URL, maxPixel: CGFloat) -> UIImage? {
        cache.object(forKey: key(url, maxPixel: maxPixel))
    }

    /// A frame a quarter-second in, scaled to `maxPixel`. Nil when the file
    /// cannot be read — the caller then keeps the kind's gradient tile, which is
    /// an honest thumbnail for a video that will not open.
    ///
    /// GATED (the build-9 lag report). Every video row starts its own `.task` on
    /// appear, so a listing with a tour, three reels, a flyover and two moving
    /// photos fired seven `AVAssetImageGenerator`s at once. Each one opens a
    /// file, parses a container and decodes an H.264 keyframe; seven of those
    /// competing is exactly the "scrolling is laggy" the owner is describing,
    /// because they saturate the same cores the scroll is running on. Two at a
    /// time fills the visible rows in the same wall-clock time without owning
    /// the machine — the rows above the fold still land first, in order.
    ///
    /// The cache probe happens BEFORE the gate on purpose: a poster we already
    /// have must never queue behind a decode.
    static func poster(for url: URL, maxPixel: CGFloat) async -> UIImage? {
        if let hit = cached(url, maxPixel: maxPixel) { return hit }
        await PosterGate.shared.acquire()
        let image = await generate(url, maxPixel: maxPixel)
        await PosterGate.shared.release()
        guard let image else { return nil }
        cache.setObject(image, forKey: key(url, maxPixel: maxPixel),
                        cost: Int(image.size.width * image.size.height * 4))
        return image
    }

    /// The decode itself, unchanged from build 8 — same time, same tolerances,
    /// same `maximumSize`. Only the queueing around it is new.
    private static func generate(_ url: URL, maxPixel: CGFloat) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        guard let result = try? await generator.image(at: CMTime(seconds: 0.25, preferredTimescale: 600))
        else { return nil }
        return UIImage(cgImage: result.image)
    }
}

/// How many poster decodes may be in flight at once.
///
/// An `actor` rather than a `DispatchSemaphore`: a semaphore's `wait()` BLOCKS
/// the thread it is called on, and blocking a cooperative-pool thread to wait
/// for other work on that same pool is how you get a stall that looks exactly
/// like the bug this file is fixing. `acquire()` suspends instead, so the thread
/// goes and does something else.
///
/// Deliberately NOT cancellation-aware. A waiter whose row disappeared still
/// gets its slot, still decodes, and still fills the cache — which is what the
/// next appearance of that row wants anyway. The queue therefore always drains:
/// every acquirer reaches `release()`, and `release()` hands the slot straight
/// to the next waiter rather than dropping it. A gate that could strand a
/// waiter would leave a thumbnail permanently blank, and a wrong thumbnail is
/// worse than a slow one.
private actor PosterGate {
    static let shared = PosterGate(limit: 2)

    private let limit: Int
    private var active = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func acquire() async {
        if active < limit {
            active += 1
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiting.append(continuation)
        }
    }

    func release() {
        if waiting.isEmpty {
            active -= 1
        } else {
            // Hand this slot over rather than freeing and re-taking it: `active`
            // is already counting the waiter that is about to run.
            waiting.removeFirst().resume()
        }
    }
}

/// The thumbnail for one FILES row: the video's real first frame, or the photo
/// itself, with the kind's gradient tile underneath until (or unless) that loads.
/// Modelled on `DetailPhotoThumb` — nothing decodes inside `body`.
private struct MediaThumb: View {
    let item: ListingMediaItem
    var side: CGFloat = 44
    var corner: CGFloat = 10
    @State private var image: UIImage?

    var body: some View {
        // Same construction as `DetailPhotoThumb` (a fixed-size clear base with
        // the picture as an OVERLAY, so a `scaledToFill` image cannot grow the
        // row) over the same gradient tile `clipsCard` uses for its icon.
        Color.clear
            .frame(width: side, height: side)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: item.icon)
                        .font(.system(size: side * 0.36, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Color.white)
                }
            }
            .background(item.gradient,
                        in: RoundedRectangle(cornerRadius: corner, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                if item.isVideo, image != nil {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: side * 0.3))
                        .foregroundStyle(Color.white)
                        .shadow(color: Color.black.opacity(0.4), radius: 2)
                        .padding(2)
                }
            }
            .task(id: item.url) { await load() }
    }

    private func load() async {
        if item.isVideo {
            // Same two-step the photo branch below already uses: take a poster we
            // already have SYNCHRONOUSLY so a row that has been on screen before
            // paints its real frame immediately, and only suspend (and queue
            // behind `PosterGate`) when there is genuinely a decode to do.
            if let hit = VideoPosters.cached(item.url, maxPixel: side * 3) {
                image = hit
            } else {
                image = await VideoPosters.poster(for: item.url, maxPixel: side * 3)
            }
        } else if item.kind == .photo {
            if let hit = ImageThumbnails.cached(item.url, maxPixel: 400) {
                image = hit
            } else {
                image = await ImageThumbnails.load(item.url, maxPixel: 400)
            }
        }
    }
}

/// Play, save and share one video from the listing's FILES section — the same
/// three things Reel Studio's finished-reel screen offers, opened straight off
/// the listing. In the 4,000 sq ft field test there was no way to reach a
/// finished reel or aerial from this screen at all.
private struct ListingFilePreview: View {
    let item: ListingMediaItem
    let listingID: UUID
    let canExport: @MainActor () -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var saved = false
    @State private var isSaving = false
    @State private var saveError: String?

    private var saveButtonTitle: String {
        if saved { return "Saved to your Photos app" }
        return isSaving ? "Saving…" : "Save to Photos"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if let player {
                        VideoPlayer(player: player)
                            .frame(height: 420)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                            .onAppear { player.play() }
                    }
                    Text("\(item.blurb) · \(item.dateLabel)")
                        .font(.rpCaption)
                        .foregroundStyle(Theme.inkDim)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Button { save() } label: {
                        Label(saveButtonTitle,
                              systemImage: saved ? "checkmark.circle.fill" : "square.and.arrow.down")
                            .font(.rpBody.weight(.semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 16)
                            .modifier(RendpropActionLabelSurface())
                    }
                    .disabled(saved || isSaving)
                    // Names the APP it landed in. "Saved to Photos" is true and
                    // reads to a lot of people as "saved, somewhere" — the whole
                    // point of the tap is that they can now go and post it.
                    if saved {
                        Text("Open the Photos app to post it.")
                            .font(.rpCaption).foregroundStyle(Theme.inkDim)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    ShareLink(item: item.url) {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .font(.rpBody.weight(.semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 13)
                            .modifier(RendpropActionLabelSurface(primary: false))
                    }
                    if let saveError {
                        Text(saveError)
                            .font(.rpCaption).foregroundStyle(Theme.warn)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // An aerial is synthetic footage and says so EVERYWHERE it is
                    // shown, this screen included (W2-C4). The server's own
                    // sentence lives with the clip's meta; this is the same
                    // fallback `AerialIntroSheet` prints when it has none.
                    if item.kind == .aerial {
                        Label(AIVideoJob.aerialFallbackDisclosure,
                              systemImage: "exclamationmark.shield.fill")
                            .font(.rpCaption.weight(.semibold))
                            .foregroundStyle(Theme.warn)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(Theme.fillSubtle,
                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
                .padding()
            }
            .background(Theme.bg)
            .navigationTitle(item.title)
            .navigationBarTitleDisplayMode(.inline)
            .askAI(.files, listingID: listingID)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        player?.pause()
                        dismiss()
                    }
                }
            }
        }
        .onAppear { if player == nil { player = AVPlayer(url: item.url) } }
        .onDisappear { player?.pause() }
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        saveError = nil
        let url = item.url
        Task {
            do {
                try await PhotosLibrarySaver.saveVideo(at: url, while: canExport)
                await MainActor.run {
                    isSaving = false
                    saved = true
                    Haptics.success()
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    saveError = error.localizedDescription
                }
            }
        }
    }
}

/// One full-screen cover for every kind of file, so the listing screen grows a
/// single presentation modifier rather than three (this file has hit the
/// type-checker's expression budget before, and `body` is already long).
/// Each branch is a viewer that already exists and already works.
private struct ListingFileViewer: View {
    let item: ListingMediaItem
    let listingID: UUID
    let canExport: @MainActor () -> Bool

    var body: some View {
        switch item.kind {
        case .photo:
            // The photo studio's own before/after view, unchanged. A photo with no
            // separate "before" on disk is its own before, exactly as
            // `EnhancedPhoto.loadAll` records it.
            // File-row identity is kind-prefixed; saved history uses the raw
            // photo version id. Keep the initial publication action accurate.
            let photoID = item.id.hasPrefix("photo-") ? String(item.id.dropFirst("photo-".count)) : item.id
            PhotoCompareView(photo: EnhancedPhoto(id: photoID,
                                                  originalURL: item.originalURL ?? item.url,
                                                  enhancedURL: item.url))
        case .floorPlan:
            // The same QuickLook presentation FloorPlanView uses for the USDZ.
            NavigationStack {
                USDZQuickLook(url: item.url)
                    .ignoresSafeArea()
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { FileViewerDoneButton() }
                    }
            }
        default:
            ListingFilePreview(item: item, listingID: listingID, canExport: canExport)
        }
    }
}

/// QuickLook has no Done button of its own inside a cover; this is the one
/// FloorPlanView puts there, factored out so the switch above stays short.
private struct FileViewerDoneButton: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View { Button("Done") { dismiss() } }
}

// MARK: - Photo studio (phone photos → pro listing images)
// Deterministic, on-device, zero-cost enhancement (shadow lift, vibrance,
// contrast, sharpen) plus AI edits through `/ai-photo`. Files live per-listing
// in Documents/Photos/<listingID>/ (enh-<id>.jpg + orig-<id>.jpg pairs).

struct EnhancedPhoto: Identifiable, Hashable, Sendable {
    let id: String
    let originalURL: URL
    let enhancedURL: URL

    var savedVersion: PhotoVersionHistory.Version? {
        guard let index = try? PhotoVersionHistory.load(directory: enhancedURL.deletingLastPathComponent()) else { return nil }
        return index.versions[id] ?? index.versions.values.first { $0.imageFile == enhancedURL.lastPathComponent }
    }
    var retainedSourceIsVerified: Bool { savedVersion?.originalVerified == true }
    var history: [EnhancedPhoto] {
        let directory = enhancedURL.deletingLastPathComponent()
        guard let index = try? PhotoVersionHistory.load(directory: directory), let version = savedVersion else { return [self] }
        return index.history(for: version.id).map { saved in
            EnhancedPhoto(id: saved.id, originalURL: directory.appendingPathComponent(saved.reviewSourceFile(in: index)),
                          enhancedURL: directory.appendingPathComponent(saved.imageFile))
        }
    }
}

/// Family navigation is a local view over this listing's retained version index.
/// It never selects a publication, changes a version, or accepts another directory.
private enum PhotoFamilyPager {
    static func family(of photo: EnhancedPhoto, index: PhotoVersionHistory.Index, directory: URL) -> String? {
        let directory = directory.standardizedFileURL
        guard photo.enhancedURL.standardizedFileURL.deletingLastPathComponent() == directory,
              photo.originalURL.standardizedFileURL.deletingLastPathComponent() == directory,
              let version = index.versions[photo.id], !index.hiddenFamilies.contains(version.familyID),
              version.imageFile == photo.enhancedURL.lastPathComponent,
              version.reviewSourceFile(in: index) == photo.originalURL.lastPathComponent,
              let attributes = try? FileManager.default.attributesOfItem(atPath: photo.enhancedURL.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.int64Value ?? 0 > 0 else { return nil }
        return version.familyID
    }

    static func photos(_ candidates: [EnhancedPhoto], index: PhotoVersionHistory.Index, directory: URL) -> [EnhancedPhoto] {
        var families: [String: EnhancedPhoto] = [:]
        for candidate in candidates {
            guard let family = family(of: candidate, index: index, directory: directory), families[family] == nil else { continue }
            families[family] = candidate
        }
        return index.orderedFamilyIDs.compactMap { families[$0] }
    }

    static func destination(from viewed: EnhancedPhoto, offset: Int, candidates: [EnhancedPhoto],
                            remembered: [String: EnhancedPhoto], index: PhotoVersionHistory.Index, directory: URL) -> EnhancedPhoto? {
        guard offset == -1 || offset == 1,
              let current = family(of: viewed, index: index, directory: directory) else { return nil }
        let ordered = photos(candidates, index: index, directory: directory)
        guard let position = ordered.firstIndex(where: { family(of: $0, index: index, directory: directory) == current }),
              ordered.indices.contains(position + offset) else { return nil }
        let next = ordered[position + offset]
        guard let target = family(of: next, index: index, directory: directory) else { return nil }
        if let saved = remembered[target], family(of: saved, index: index, directory: directory) == target { return saved }
        return next
    }

    static func swipeOffset(horizontal: Double, vertical: Double) -> Int? {
        guard horizontal.isFinite, vertical.isFinite, abs(horizontal) >= 60,
              abs(horizontal) > abs(vertical) * 1.5 else { return nil }
        return horizontal < 0 ? 1 : -1
    }
}

/// Presentation carries the user's cover intent atomically with its photo.
/// A separate state read inside the cover closure can retain the old value.
private struct PhotoComparePresentation: Identifiable {
    let photo: EnhancedPhoto
    var requestedCover = false
    var id: String { photo.id }
}

extension EnhancedPhoto {
    nonisolated static func loadForListing(listingID: UUID) throws -> [EnhancedPhoto] {
        let directory = directory(for: listingID)
        guard let choices = try PhotoVersionHistory.publicationVersions(directory: directory) else {
            return loadAll(listingID: listingID)
        }
        let index = try PhotoVersionHistory.load(directory: directory)
        return index.orderedForLibrary(choices).map { version in
            let output = directory.appendingPathComponent(version.imageFile)
            return EnhancedPhoto(id: version.id, originalURL: directory.appendingPathComponent(version.reviewSourceFile(in: index)),
                                 enhancedURL: output)
        }
    }
    /// Per-listing photo directory (Documents/Photos/<listingID>/). Not created here.
    static func directory(for listingID: UUID) -> URL {
        FileStore.documents.appendingPathComponent("Photos/\(listingID.uuidString)", isDirectory: true)
    }

    /// Current photo versions in source import order. Older files remain
    /// addressable without moving a family when its editing version changes.
    nonisolated static func loadAll(listingID: UUID) -> [EnhancedPhoto] {
        let dir = directory(for: listingID)
        return dated(in: DiskScan.entries(of: dir), directory: dir).map(\.photo)
    }

    /// Reuse one directory scan for legacy files and the durable version index.
    /// A legacy orig-* filename alone does not certify an unaltered original.
    nonisolated fileprivate static func dated(in entries: [DatedFile],
                                              directory dir: URL) -> [DatedPhoto] {
        let names = Set(entries.map(\.name))
        let history = try? PhotoVersionHistory.load(directory: dir)
        let knownFiles = Dictionary((history?.versions.values.map { ($0.imageFile, $0) } ?? []),
                                    uniquingKeysWith: { first, _ in first })
        let positions = Dictionary(uniqueKeysWithValues: (history?.orderedFamilyIDs ?? []).enumerated().map { ($0.element, $0.offset) })
        return entries.compactMap { file -> DatedPhoto? in
            if let version = knownFiles[file.name] {
                guard history?.isVisible(version.id) == true else { return nil }
                let source = history.map { dir.appendingPathComponent(version.reviewSourceFile(in: $0)) } ?? file.url
                return DatedPhoto(photo: EnhancedPhoto(id: version.id, originalURL: source, enhancedURL: file.url),
                                  createdAt: version.createdAt)
            }
            // Legacy files stay visible without inferring edit history. New edit-
            // files are visible only after their atomic metadata commit succeeds.
            guard file.name.hasPrefix("enh-") else { return nil }
            let id = String(file.url.deletingPathExtension().lastPathComponent.dropFirst(4))
            let preferredOriginal = "orig-\(id).jpg"
            let originalName = names.contains(preferredOriginal) ? preferredOriginal
                : names.sorted().first(where: { $0.hasPrefix("orig-\(id).") })
            let original = originalName.map { dir.appendingPathComponent($0) } ?? file.url
            return DatedPhoto(photo: EnhancedPhoto(id: id, originalURL: original, enhancedURL: file.url),
                              createdAt: file.createdAt)
        }.sorted { a, b in
            let aFamily = history?.versions[a.photo.id]?.familyID ?? a.photo.id
            let bFamily = history?.versions[b.photo.id]?.familyID ?? b.photo.id
            let aOrder = positions[aFamily] ?? Int.max, bOrder = positions[bFamily] ?? Int.max
            if aOrder != bOrder { return aOrder < bOrder }
            return a.createdAt != b.createdAt ? a.createdAt < b.createdAt : a.photo.id > b.photo.id
        }
    }
}

/// One virtual-staging style, exactly as the staging dialog has always offered
/// them and in the same order.
///
/// FILE SCOPE and `Identifiable` so `ForEach` can take the array straight. `id`
/// is the exact string `aiEdit(_:_:style:)` / `performEdit` send as `style`, so
/// the row on the surface cannot drift from what the server is asked for.
///
/// The wand's own "Pick a style" dialog and the long-press menu still spell the
/// four out by hand. That is deliberate for now: the brief was to leave the wand
/// exactly as it is, and those two lists are already correct. When one of them
/// is next touched it should be pointed at `StagingStyle.all` instead.
private struct StagingStyle: Identifiable, Hashable {
    let id: String
    let label: String

    /// Modern / Rustic / Minimalist / Contemporary. `let` on a file-scope
    /// `private` type: no actor, no isolation question, readable from anywhere.
    static let all: [StagingStyle] = [
        StagingStyle(id: "modern", label: "Modern"),
        StagingStyle(id: "rustic", label: "Rustic"),
        StagingStyle(id: "minimalist", label: "Minimalist"),
        StagingStyle(id: "contemporary", label: "Contemporary"),
    ]
}

/// One edit the agent picked off the studio's edit bar, waiting for them to say
/// which photos it applies to.
///
/// FILE SCOPE, not nested in `PhotoStudioView`, and deliberately so. A `View` is
/// `@MainActor`, so a type nested inside one inherits that isolation and every
/// touch of it from a non-isolated context is an argument the compiler wins —
/// the Mac build has already caught one call of exactly that shape
/// (`normalizedASIN`, commit 78c4610). This is plain data with no statics; it
/// has no reason to be isolated to anything.
private struct PendingBatchEdit: Identifiable, Equatable {
    /// The `edit` string `aiEdit`/`performEdit` take — twilight | sky | lawn |
    /// declutter | stage | custom | animate. Never a new vocabulary.
    let edit: String
    /// Staging style, when the edit is `stage`. nil everywhere else.
    let style: String?
    /// The words the bar showed, reused verbatim in the selection bar and the
    /// progress line so the agent never has to match a label to a job.
    let title: String
    /// False for edits that must not fan out — "Turn it into video" is a
    /// ~1-minute poll and a separate charge PER PHOTO, so the grid lets exactly
    /// one photo be ticked for it.
    let multiple: Bool

    var id: String { style.map { "\(edit).\($0)" } ?? edit }
}

@MainActor private struct PhotoStagingSetup: Identifiable {
    let id = UUID()
    let pending: PendingBatchEdit
    let targets: [EnhancedPhoto]
    let references: [EnhancedPhoto]
    private let owner = AuthStore.shared.userID
    private let revision = AuthStore.shared.syncSessionRevision
    private let workspace = WorkspaceContext.selectedOrgID
    var isCurrent: Bool {
        AuthStore.shared.userID == owner && AuthStore.shared.syncSessionRevision == revision
            && WorkspaceContext.selectedOrgID == workspace
    }
}

private struct PhotoStagingSetupView: View {
    let setup: PhotoStagingSetup
    let apply: (String?, String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var referenceID = ""
    @State private var brief = ""
    @State private var sameRoomConfirmed = false
    private var reference: EnhancedPhoto? { setup.references.first { $0.id == referenceID } }

    var body: some View {
        NavigationStack {
            Form {
                Section("Staging · \((setup.pending.style ?? "modern").capitalized)") {
                    Text("\(setup.targets.count) selected photo\(setup.targets.count == 1 ? "" : "s"). Each photo is a separate edit and counts against your plan.")
                    TextField("Furnishing brief (optional)", text: $brief, axis: .vertical)
                        .lineLimit(2...4).onChange(of: brief) { value in
                            if value.count > 600 { brief = String(value.prefix(600)) }
                        }
                    Text("Reuse a specific furniture description when you stage another angle of this room. Fixed features and clear access take priority.").font(.caption)
                }
                Section("Another view of the same room") {
                    Picker("Furniture reference · Coming soon", selection: $referenceID) {
                        Text("No reference").tag("")
                        ForEach(setup.references) { photo in
                            Text(photo.savedVersion?.title ?? "Reviewed staged photo").tag(photo.id)
                        }
                    }.disabled(true).onChange(of: referenceID) { _ in sameRoomConfirmed = false }
                    if let reference {
                        DetailPhotoThumb(url: reference.enhancedURL, height: 180)
                        Toggle("This is the same room and I checked this furniture layout", isOn: $sameRoomConfirmed)
                    } else if setup.references.isEmpty {
                        Text("Furniture references are coming soon.")
                    }
                    Text("Same-room photo references are not available yet. Use the same furnishing brief for each view, then compare every output; matching furniture is not guaranteed.").font(.caption)
                }
                Section {
                    Button("Stage \(setup.targets.count) photo\(setup.targets.count == 1 ? "" : "s")") {
                        guard setup.isCurrent, referenceID.isEmpty || sameRoomConfirmed else { return }
                        dismiss()
                        apply(referenceID.isEmpty ? nil : referenceID, brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : brief)
                    }.disabled(!setup.isCurrent || (!referenceID.isEmpty && !sameRoomConfirmed))
                        .accessibilityIdentifier("photoStage.apply")
                    if !setup.isCurrent { Text("Your account or workspace changed. Reopen Staging.").foregroundStyle(.orange) }
                }
            }
            .navigationTitle("Stage selected photos").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

/// The one-line verdict left on screen after a batch. `ok` is false when any
/// photo failed, so the card can stop claiming success it did not have.
private struct BatchNote: Equatable {
    let text: String
    let ok: Bool
}

/// Live counters for a running batch. `current` is 1-based and is the photo
/// being worked on right now, so the card reads "photo 3 of 17".
private struct BatchRun: Equatable {
    let title: String
    let total: Int
    var current: Int = 1
    var done: Int = 0
    var failed: Int = 0
    var phase: PhotoWorkQueue.Phase = .preparing
}

private struct PhotoOrientationFilterControl: View {
    @Binding var filter: PhotoOrientation?
    let orientations: [PhotoOrientation]
    var selectedCount: Int? = nil
    var identifier = "photos.orientation"

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(orientations.count) photos" + (selectedCount.map { " · \($0) selected" } ?? ""))
                    .font(.rpCaption.weight(.semibold)).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Menu {
                    Picker("Photo orientation", selection: $filter) {
                        Text("All photos").tag(Optional<PhotoOrientation>.none)
                        ForEach(PhotoOrientation.allCases, id: \.self) { orientation in
                            Text("\(orientation.label) (\(PhotoOrientation.counts(orientations)[orientation, default: 0]))")
                                .tag(Optional(orientation))
                        }
                    }
                } label: {
                    Label(filter?.label ?? "All photos", systemImage: "line.3.horizontal.decrease")
                        .font(.rpCaption.weight(.semibold)).foregroundStyle(Theme.accent)
                        .padding(.horizontal, 10).frame(minHeight: 44)
                        .background(Theme.fillSubtle, in: RoundedRectangle(cornerRadius: 10))
                }
                .accessibilityLabel("Filter photo orientation")
                .accessibilityValue(filter?.label ?? "All photos")
                .accessibilityIdentifier(identifier + ".filter")
            }
            Text(PhotoOrientation.summary(orientations))
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(identifier + ".counts")
            if filter != nil, selectedCount != nil {
                Text("Filtering keeps your selected photos and their order.")
                    .font(.rpCaption).foregroundStyle(Theme.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PhotoStudioView: View {
    /// WHICH OF THE TWO SCREENS THIS IS.
    ///
    /// One view, one set of state, one photo directory - two entry points, and
    /// they are genuinely two screens, not one screen with a flag on it.
    ///
    /// THE DEFECT this fixes is the one the owner reported more times than any
    /// other: uploading photos and changing photos were the same screen. That
    /// is why "AI Photo Studio" opened on a wall of thumbnails instead of a
    /// menu of what the AI can do - the screen had to be a photo manager
    /// first, so the AI was whatever was left over. Renaming the buttons on it
    /// (twice) never had a chance, because the problem was never a word.
    ///
    ///  * `.photos` - YOUR PHOTOS. Add them, see them, pick the cover, share,
    ///    delete. Every photo is brightened and sharpened on the way in
    ///    (`ingest` -> `PhotoEnhancer.enhance`), free and on-device. No AI menu.
    ///    It is a library.
    ///  * `.studio` - AI PHOTO STUDIO. Opens on the MODES, full stop. Declutter,
    ///    Staging (four styles on the surface), Twilight, Sky, Lawn, Ask for
    ///    anything, Turn it into video. Pick one, and THEN the photos already
    ///    uploaded appear to be ticked. Mode first, photos second.
    enum Entry { case photos, studio }

    // `enum Intent { case photos, reel }` and `var intent` are GONE, together
    // with the reel card they existed to ring. The "Make a reel" tile on the
    // listing screen (and the app's `.reel` deep-link route) opens
    // `ReelStudioView` directly now, so there is no longer such a thing as
    // "the photo studio, opened for a reel". Nothing here reads an intent, so
    // nothing here carries one.

    /// One place for the words on every edit button, so the always-on edit bar,
    /// the wand menu and the long-press menu can never drift apart. Plain words,
    /// no jargon — EXCEPT where the plain word would hide the feature's actual
    /// name, which is what happened to Declutter (below). The COMPLIANCE wording
    /// is separate and unchanged — `provenanceLabel` still writes "Declutter" /
    /// "Virtual staging" to the disclosure, which is the language a broker's
    /// audit log needs.
    private enum EditWords {
        static let twilight  = "Make it twilight"
        static let sky       = "Make the sky blue"
        static let lawn      = "Make the lawn green"
        /// "Declutter" is the FEATURE'S NAME and has to be visible. Commit 8ee0c6c
        /// replaced the word outright with "Tidy the room"; in the 4,000 sq ft
        /// field test the owner searched the UI for "Declutter", could not find it
        /// anywhere, and reported the feature as removed. The plain-words gloss
        /// still exists — as a subtitle under the word, never instead of it.
        static let declutter = "Declutter"
        static let declutterGloss = "Tidies the room"
        static let animate   = "Turn it into video"
        static let custom    = "Ask for anything"
        static let suggest   = "Suggest edits for this photo"
        static func stage(_ space: SpaceType) -> String {
            space == .realEstate ? "Add furniture" : "Furnish it"
        }

        /// THE FEATURE'S NAME, on the surface, for the same reason `declutter`
        /// is: the owner calls it staging, the industry calls it staging, and
        /// `stage(_:)` above returns "Add furniture" on real estate — so the
        /// word *staging* appeared nowhere an agent could see it. He reported it
        /// missing alongside Declutter, twice.
        ///
        /// `stage(_:)` is NOT replaced: it is still the wand menu's and the
        /// long-press menu's wording, and it is the plain-words gloss under this
        /// heading. Word on top, gloss underneath — never the gloss instead of
        /// the word (see `declutter`).
        ///
        /// Off real estate there is no industry term for furnishing a gym, so
        /// the plain word IS the name; `stagingLabel` still carries the exact
        /// wording ("Virtual staging" / "Furnish & style") into the disclosure.
        static func staging(_ space: SpaceType) -> String {
            space == .realEstate ? "Staging" : "Furnish it"
        }

        /// The sentence under the staging heading. On real estate it opens with
        /// the literal words `stage(.realEstate)` used to say, so nothing an
        /// agent already learned to look for disappeared off the screen.
        static func stagingGloss(_ space: SpaceType) -> String {
            space == .realEstate
                ? "Add furniture in the style you pick. Review every result against the original before publishing."
                : "Add furniture and decor in the style you pick. Review fixed features and access against the original before publishing."
        }

    }

    /// A photo→motion clip already on disk for this listing
    /// (`Photos/<listingID>/clip-*.mp4`). Listed so a finished animation is
    /// still reachable after its sheet closes, and deletable so the mp4s don't
    /// pile up invisibly (F-A-23).
    struct SavedClip: Identifiable, Hashable {
        let id: String          // file name — unique within the listing's folder
        let url: URL
        let createdAt: Date

        /// Every `clip-*.mp4` in a listing's photo folder, newest first.
        ///
        /// SIGNATURE UNCHANGED and still synchronous — the studio calls it from
        /// `loadExisting()` and again the moment an animation lands, and neither
        /// wanted an `await`. What changed is where the glob lives: it is
        /// `DiskScan.motionClips` now, so the listing screen's background scan
        /// can run the SAME filter without calling in here.
        ///
        /// That last part is the point, and it is a Swift 6 isolation point, not
        /// a taste one. `SavedClip` is nested inside a `View`, and a `View` is
        /// `@MainActor`; build 8's `ListingMediaItem.loadAll` was annotated
        /// `@MainActor` for exactly that reason, which is how fifty filesystem
        /// calls ended up in front of the first frame. Rather than argue about
        /// whether a nested type inherits its parent's isolation — the Mac build
        /// has already caught one call of that shape — the shared work moved to
        /// a file-scope type that is unambiguously non-isolated, and this stays
        /// a thin main-actor wrapper for the callers that want one.
        static func loadAll(listingID: UUID) -> [SavedClip] {
            let dir = EnhancedPhoto.directory(for: listingID)
            return DiskScan.motionClips(in: DiskScan.entries(of: dir))
                .map { SavedClip(id: $0.name, url: $0.url, createdAt: $0.createdAt) }
        }
    }

    @EnvironmentObject var model: AppModel
    @ObservedObject private var auth = AuthStore.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let listing: Listing
    let entry: Entry

    private var mainRelPath: String? {
        model.listings.first(where: { $0.id == listing.id })?.mainPhotoRelPath
    }
    private func isMain(_ p: EnhancedPhoto) -> Bool {
        if model.listings.first(where: { $0.id == listing.id })?.serverID != nil {
            return model.cloudPhotoProjection(for: listing.id)?.coverVersionIDs.contains(p.id) == true
        }
        return mainRelPath == FileStore.relativePath(for: p.enhancedURL)
    }
    private var isCloudPhotoListing: Bool { model.listings.first(where: { $0.id == listing.id })?.serverID != nil }
    private func listingPhotoSelected(_ id: String) -> Bool {
        isCloudPhotoListing ? model.cloudPhotoProjection(for: listing.id)?.selectedVersionIDs.contains(id) == true : selectedPhotoIDs.contains(id)
    }
    private func listingPhotoLabel(_ id: String) -> String? {
        isCloudPhotoListing ? (model.cloudPhotoProjection(for: listing.id)?.label(versionID: id) ?? "Check listing selection") : publicationLabels[id]
    }

    // `aerialClipURLs` moved OUT of this screen with the reel card. The aerial
    // intro still rides into Reel Studio as `extraClipURLs` — it is handed over
    // by `FlythroughDetailView`'s "Make a reel" cover now, which is the screen
    // that owns the tile the agent actually taps.

    /// This listing's server row, when it already has one. Sent with the prompt
    /// assist so the server's fair-housing gate is scoped to THIS listing's real
    /// space type (COPY-ASSIST-CONTRACT §5) — without it the gate falls back to
    /// the strictest, housing rules, which is right for a home and would refuse
    /// a restaurant's "family-style patio".
    ///
    /// Read straight off the model rather than through
    /// `serverListingIDForCompliance`: that helper CREATES the server listing
    /// when there isn't one, and a text-only prompt rewrite is not a reason to
    /// make a row on the server. An unsynced listing simply gets the strict
    /// gate, which fails closed.
    private var listingServerID: UUID? {
        guard !listing.isSample else { return nil }
        return (model.listings.first(where: { $0.id == listing.id }) ?? listing).serverID
    }

    private func setMain(_ p: EnhancedPhoto) {
        if isCloudPhotoListing {
            if p.savedVersion?.needsStagingReview == true || p.savedVersion?.needsCustomReview == true {
                compare = PhotoComparePresentation(photo: p, requestedCover: true)
                return
            }
            let context = NativeMediaExportContext()
            galleryRetrying = true
            Task { @MainActor in
                defer { galleryRetrying = false }
                do {
                    _ = try await model.makeCloudPhotoCover(listingID: listing.id, versionID: p.id, reviewed: false)
                    if context.isCurrent { Haptics.success() }
                    if context.isCurrent {
                        PhotoFeedbackQueue.shared.recordListingSelection(of: p.savedVersion, stagingAcknowledged: false,
                            customAcknowledged: false,
                            listingIsLive: model.listings.first(where: { $0.id == listing.id })?.serverShareURL != nil)
                    }
                } catch { if context.isCurrent { photoSaveError = error.localizedDescription } }
            }
            return
        }
        do {
            let directory = p.enhancedURL.deletingLastPathComponent()
            try PhotoVersionHistory.trackExisting(id: p.id, imageFile: p.enhancedURL.lastPathComponent,
                priorFile: p.originalURL == p.enhancedURL ? nil : p.originalURL.lastPathComponent, directory: directory)
            try PhotoVersionHistory.selectForPublication(id: p.id, directory: directory)
        } catch PhotoVersionHistory.Failure.reviewRequired {
            compare = PhotoComparePresentation(photo: p, requestedCover: true); return
        } catch PhotoVersionHistory.Failure.customReviewRequired {
            compare = PhotoComparePresentation(photo: p, requestedCover: true); return
        } catch {
            aiFailure = AIFailure(error); return
        }
        loadExisting()
        model.setMainPhoto(FileStore.relativePath(for: p.enhancedURL), for: listing.id)
        Haptics.success()
        PhotoFeedbackQueue.shared.recordSignal(.manualSelection, detail: .listingSelection, for: p.savedVersion)
    }

    /// The business type the copy speaks in (samples follow the current type).
    private var space: SpaceType { listing.isSample ? SpaceType.current : listing.spaceType }
    /// The INDUSTRY term, used only where it must be exact: the staging
    /// dialog's explanation and the disclosure copy. Buttons say "Add furniture"
    /// (see `EditWords`) — plain words on the button, honest words in the note.
    private var stagingLabel: String { space == .realEstate ? "Virtual staging" : "Furnish & style" }

    @State private var photos: [EnhancedPhoto] = []
    @State private var libraryKind: PhotoVersionHistory.LibraryKind = .original
    @State private var photoOrientationFilter: PhotoOrientation?
    @State private var photoOrientations: [PhotoGeometryInput: PhotoOrientation] = [:]
    @State private var selectedPhotoIDs: Set<String> = []
    @State private var publicationLabels: [String: String] = [:]
    @State private var galleryRetrying = false
    @State private var listingChoiceWorkID: UUID?
    @State private var listingChoiceTask: Task<Void, Never>?
    @State private var listingChoiceIDs: Set<String> = []
    @State private var listingChoiceNote: String?
    @State private var listingCoverTargets: [PhotoGridListingSelection.Target] = []
    @State private var listingCoverContext: NativeMediaExportContext?
    @State private var confirmListingCoverFollow = false
    @State private var listingCoverIsToggle = false
    private var libraryPhotos: [EnhancedPhoto] {
        guard entry == .photos, libraryKind != .latest else { return photos }
        guard let index = try? PhotoVersionHistory.load(directory: EnhancedPhoto.directory(for: listing.id)) else { return [] }
        let directory = EnhancedPhoto.directory(for: listing.id)
        return index.libraryVersions(libraryKind).map { version in
            let image = directory.appendingPathComponent(version.imageFile)
            return EnhancedPhoto(id: version.id, originalURL: directory.appendingPathComponent(version.reviewSourceFile(in: index)),
                                 enhancedURL: image)
        }
    }
    private var photoGeometryInputs: [PhotoGeometryInput] {
        libraryPhotos.map { PhotoGeometryInput(id: $0.id, url: $0.enhancedURL) }
    }
    private func photoOrientation(_ photo: EnhancedPhoto) -> PhotoOrientation {
        photoOrientations[PhotoGeometryInput(id: photo.id, url: photo.enhancedURL)] ?? .unknown
    }
    private var filteredLibraryPhotos: [EnhancedPhoto] {
        PhotoOrientation.filtered(libraryPhotos, by: photoOrientationFilter, orientation: photoOrientation)
    }

    private var galleryFamilyPhotos: [EnhancedPhoto] {
        let directory = EnhancedPhoto.directory(for: listing.id)
        guard let index = try? PhotoVersionHistory.load(directory: directory) else { return [] }
        return PhotoFamilyPager.photos(libraryPhotos + photos, index: index, directory: directory)
    }

    private var gallerySyncError: String? {
        guard let message = model.listings.first(where: { $0.id == listing.id })?.lastError,
              message.hasPrefix(AppModel.photoSyncErrorPrefix) else { return nil }
        return message
    }
    /// The photos with AI work in flight right now, so each THUMBNAIL can say
    /// so. `isProcessing` is one bool for the whole screen and its spinner
    /// renders once, at the top of the scroll view — on a seventeen-photo grid
    /// that is a thousand points above the photo you just tapped, which is how
    /// the owner ended up tapping Declutter and having "no idea if it was
    /// working or not until I got that message".
    @State private var busyPhotoIDs: Set<String> = []
    @State private var showLibrary = false
    @State private var showCamera = false
    @State private var showCaptureGuide = false
    @State private var openCameraAfterGuide = false
    var captureIntent: CaptureGuideIntent = .listingPhotos
    @State private var localProcessing = false
    @State private var libraryImportID: UUID?
    @State private var libraryImportCancellation: PhotoImportCancellation?
    @ObservedObject private var photoJobs = PhotoWorkQueue.shared
    @State private var handledPhotoJob: UUID?
    private var isProcessing: Bool { localProcessing || checkingSavedPhoto || photoJobs.job?.running == true }
    @State private var photoSaveError: String?
    @State private var processingText = "Working on your photo…"
    @State private var compare: PhotoComparePresentation?
    @State private var exportingPhotos: PhotoExportSelection?
    @State private var photoOwner = AuthStore.shared.userID
    @State private var aiFailure: AIFailure?
    @State private var animatedClip: AnimatedClip?   // finished photo→reel clip
    @State private var customEditPhoto: EnhancedPhoto?   // photo awaiting a custom-prompt AI edit
    @State private var animateTask: Task<Void, Never>?   // polling stops on leaving; its exact paid receipt remains
    @State private var savedPhotoEdits: [PhotoPendingEdit.Saved] = []
    @State private var checkingSavedPhoto = false
    @State private var savedPhotoNote: String?
    @State private var savedPhotoReadError: String?
    @State private var savedAnimations: [PhotoAnimationRecovery.Summary] = []
    @State private var wandPhoto: EnhancedPhoto?         // photo under the visible wand button
    @State private var showWandDialog = false            // wand → change-this-photo chooser
    @State private var stagePhoto: EnhancedPhoto?        // photo awaiting a staging style
    @State private var stagingSetup: PhotoStagingSetup?
    @State private var declutterReview: PhotoDeclutterReviewModel?
    @State private var showStageDialog = false           // staging style chooser
    @State private var suggestResult: SuggestResult?     // AI-suggested edits sheet payload
    @StateObject private var connection = FeatureSessionAction()
    /// The edit an EDIT-BAR CHIP asked for while there were no photos yet. The
    /// chips used to be decoration; now one picks a photo and this remembers what
    /// to do with it the moment the import lands. Cleared on a cancelled picker.
    @State private var pendingShowcaseEdit: String?
    /// The staging style that chip carried, when it was a style button. Without
    /// it, tapping "Rustic" on an empty studio picked a photo and then asked
    /// which style — a question the agent had already answered.
    @State private var pendingShowcaseStyle: String?
    /// The edit chosen from the always-on edit bar and now waiting for the agent
    /// to say WHICH photos it applies to. Non-nil == the grid is in selection
    /// mode. With 17 photos on a listing, "tap the wand, pick Declutter"
    /// seventeen times is the workflow this replaces.
    @State private var batchEdit: PendingBatchEdit?
    /// Photo ids ticked in the grid while `batchEdit` is live.
    @State private var batchSelection: Set<String> = []
    /// The batch currently running, for the progress card. nil when idle.
    @State private var batchRun: BatchRun?
    /// What the last batch did, in one line, kept on screen until the agent
    /// starts something else. A batch that half-worked has to SAY so.
    @State private var batchNote: BatchNote?
    /// Photos a "Ask for anything" batch is waiting to apply its prompt to.
    /// `CustomEditSheet` edits one photo's worth of prompt; the prompt it
    /// returns is applied to every photo in here.
    @State private var customBatchTargets: [EnhancedPhoto] = []
    /// A photo awaiting confirmation before its family is hidden from the gallery.
    @State private var pendingPhotoDelete: EnhancedPhoto?
    @State private var showPhotoDeleteConfirm = false
    /// Motion clips already on disk for this listing (F-A-23). Without this the
    /// mp4s written by "Animate" were invisible the moment their sheet closed —
    /// unreachable, unshareable, and still taking up space.
    @State private var clips: [SavedClip] = []
    /// A stored clip awaiting the delete confirmation.
    @State private var pendingClipDelete: SavedClip?
    @State private var showClipDeleteConfirm = false
    /// True while `IdleTimer` is held for this screen, so hold/release stay
    /// balanced across covers (F-A-05: an animate is a ~1-minute wait and the
    /// screen must not sleep through it).
    @State private var idleHeld = false

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    private var dir: URL {
        let d = EnhancedPhoto.directory(for: listing.id)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// True while something is presented OVER this view. A fullScreenCover
    /// fires the presenter's `onDisappear` — cancelling the animate task there
    /// left the grid stuck on "Animating photo…" forever (F-A-12).
    private var isPresentingOverlay: Bool {
        compare != nil || exportingPhotos != nil || stagingSetup != nil || declutterReview != nil || animatedClip != nil || customEditPhoto != nil || suggestResult != nil
            || showLibrary || showCamera
            || showWandDialog || showStageDialog || showPhotoDeleteConfirm
            || showClipDeleteConfirm
    }

    /// Keep the ref-counted idle-timer hold in step with `isProcessing`, and
    /// never double-hold or double-release. Called from onAppear (a dismissed
    /// cover re-appears with the work still running), onChange and onDisappear.
    private func syncIdleHold() {
        if isProcessing, !idleHeld {
            IdleTimer.hold()
            idleHeld = true
        } else if !isProcessing, idleHeld {
            IdleTimer.release()
            idleHeld = false
        }
    }

    private func releaseIdleHold() {
        if idleHeld {
            IdleTimer.release()
            idleHeld = false
        }
    }

    // Split into three chained sub-views: the whole chain in one
    // expression exceeded the type-checker's budget (build error at
    // "unable to type-check this expression in reasonable time").
    private var studioCore: some View {
        ScrollView {
            Group {
                switch entry {
                case .photos: photosBody
                case .studio: studioBody
                }
            }
            .padding()
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if localProcessing && libraryImportID == nil {
                workingPill
                    .padding(.horizontal).padding(.vertical, 8)
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.86), value: isProcessing)
        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.86), value: busyPhotoIDs)
        .background(Theme.bg)
        .navigationTitle(entry == .photos ? "Photos" : "AI Photo Studio")
        .navigationBarTitleDisplayMode(.inline)
        .askAI(entry == .photos ? .photos : .photoStudio, listingID: listing.id,
               photoState: .init(tab: entry == .photos ? (CoachRequest.PhotoState.Tab(rawValue: libraryKind.rawValue.lowercased()) ?? .original) : .original,
                                 selectedCount: selectedPhotoIDs.count))
        .toolbar {
            ToolbarItem(placement: .principal) { studioTitleBar }
        }
        .onAppear {
            loadExisting()
            receivePhotoWork(photoJobs.visibleJob)
            syncIdleHold()      // a dismissed cover re-appears mid-animate
            seedPhotosForUIWalk()
            refreshListingPhotoSelection()
        }
        .onReceive(photoJobs.$job) { job in receivePhotoWork(photoJobs.isContextCurrent ? job : nil) }
        .onChange(of: isProcessing) { _ in syncIdleHold() }
        .onChange(of: auth.userID) { newOwner in
            libraryImportCancellation?.cancel()
            // Initial anonymous connection is expected when the first AI tap
            // reconnects. A change from an established owner closes old media.
            if photoOwner != nil, photoOwner != newOwner { declutterReview?.cancel(); declutterReview = nil; animateTask?.cancel(); animatedClip = nil; savedAnimations = []; compare = nil; exportingPhotos = nil; stagingSetup = nil; dismiss() }
            photoOwner = newOwner
        }
        .onChange(of: auth.syncSessionRevision) { _ in libraryImportCancellation?.cancel(); declutterReview?.cancel(); declutterReview = nil }
        .onReceive(NotificationCenter.default.publisher(for: .rendpropWorkspaceChanged)) { _ in
            libraryImportCancellation?.cancel()
            declutterReview?.cancel(); declutterReview = nil; animateTask?.cancel(); animatedClip = nil; savedAnimations = []; compare = nil; exportingPhotos = nil; stagingSetup = nil; dismiss()
        }
        .onDisappear {
            listingChoiceTask?.cancel()
            if !isPresentingOverlay { animateTask?.cancel() }
            releaseIdleHold()   // re-taken by onAppear when the work is still running
        }
    }


    // MARK: - Screen one: YOUR PHOTOS
    //
    // Upload, enhance, keep. This screen never shows an AI menu. The one AI
    // affordance on it is the wand in a thumbnail's corner, which is a
    // per-photo shortcut and has always been one. Everything that costs money
    // and needs a decision lives on the other screen.

    private var photosImportLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 10))
            : AnyLayout(HStackLayout(spacing: 10))
    }

    private var photosBody: some View {
        VStack(spacing: Theme.spacing) {
            photosImportLayout {
                addButton("Add photos", "photo.stack", filled: true) { showLibrary = true }
                addButton("Take a photo", "camera", filled: false) {
                    showCaptureGuide = true
                }
                .accessibilityIdentifier("photos.takePhoto")
            }
            .disabled(isProcessing)

            savedPhotoEditCard

            if let photoSaveError {
                Text(photoSaveError)
                    .font(.rpCaption).foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if photos.isEmpty && !isProcessing {
                photosEmptyState
            }

            if isProcessing && batchRun == nil {
                studioSpinnerRow
            }

            if !photos.isEmpty {
                PhotoSavedVersionTabs(selection: $libraryKind).disabled(listingChoiceWorkID != nil)
                Text(libraryKind == .original
                     ? "Your originals stay unchanged. Start an AI edit here, then review the saved result."
                     : libraryKind == .latest ? "The latest saved version of each photo. Originals and earlier edits stay available."
                     : "Your saved results. Review, select for your listing, or share a version you like.")
                    .font(.rpCaption).foregroundStyle(Theme.inkDim).fixedSize(horizontal: false, vertical: true)
                photosGridHint
            }

            if let gallerySyncError {
                VStack(alignment: .leading, spacing: 10) {
                    Text(gallerySyncError).font(.rpCaption).foregroundStyle(Theme.warn)
                        .fixedSize(horizontal: false, vertical: true)
                    Button { retryPublishedPhotos() } label: {
                        Label(galleryRetrying ? "Updating published photos…" : "Retry published photos", systemImage: "arrow.clockwise")
                    }
                    .disabled(galleryRetrying).accessibilityIdentifier("photos.retryPublishedPhotos")
                    if let review = galleryReviewPhoto {
                        Button { compare = PhotoComparePresentation(photo: review, requestedCover: true) } label: {
                            Label("Review cover selection", systemImage: "photo.on.rectangle")
                        }.accessibilityIdentifier("photos.reviewPublishedSelection")
                        Text("The cover must be a selected saved version. Review it separately; Retry only resends the selected gallery.")
                            .font(.rpCaption).foregroundStyle(Theme.inkDim)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).card()
            }
            photoGrid
            if !photos.isEmpty && libraryPhotos.isEmpty {
                Text(libraryKind == .original ? "No retained originals are available here. Add the original photos to start a new edit."
                     : libraryKind == .decluttered ? "No decluttered photos saved yet. Start from Original and choose Declutter."
                     : libraryKind == .enhanced ? "No enhanced photos saved yet. Saved enhancements will appear here."
                     : "No staged photos saved yet. Start from Original and choose a staging style.")
                    .font(.rpBody).foregroundStyle(Theme.inkDim)
            }

            if !photos.isEmpty {
                if libraryKind == .original { openStudioCard }
                shareAllButton
            }

            pendingAnimationCard
            clipsCard
        }
    }

    private var savedPhotoEditCard: some View {
        Group {
            if !savedPhotoEdits.isEmpty || savedPhotoReadError != nil || savedPhotoNote != nil {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Saved photo edits").font(.rpBody.weight(.semibold)).foregroundStyle(Theme.ink)
                    Text("Check a saved result without starting or paying for another edit. Your originals stay unchanged.")
                        .font(.rpCaption).foregroundStyle(Theme.inkDim)
                    ForEach(savedPhotoEdits) { saved in
                        Button {
                            checkSavedPhoto(saved)
                        } label: {
                            Label(checkingSavedPhoto ? "Checking saved edit…" : "Check saved edit · \(saved.request.edit.capitalized)",
                                  systemImage: "arrow.clockwise")
                                .font(.rpBody.weight(.semibold)).frame(minHeight: 44)
                        }.disabled(isProcessing).accessibilityIdentifier("photos.checkSavedEdit." + saved.id)
                    }
                    if let savedPhotoNote { Text(savedPhotoNote).font(.rpCaption).foregroundStyle(Theme.inkDim) }
                    if let savedPhotoReadError { Text(savedPhotoReadError).font(.rpCaption).foregroundStyle(Theme.warn) }
                }.frame(maxWidth: .infinity, alignment: .leading).card()
                    .accessibilityIdentifier("photos.savedEdits")
            }
        }
    }

    private func refreshSavedPhotoEdits() {
        guard let actor = AuthStore.shared.userID, let library = WorkspaceContext.selectedOrgID else {
            savedPhotoEdits = []; savedPhotoReadError = nil; return
        }
        do {
            savedPhotoEdits = try PhotoPendingEdit.saved(actor: actor, library: library, listing: listing.id, directory: dir)
            savedPhotoReadError = nil
        } catch {
            savedPhotoEdits = []; savedPhotoReadError = error.localizedDescription
        }
    }

    private func checkSavedPhoto(_ saved: PhotoPendingEdit.Saved) {
        guard !isProcessing else { return }
        let service = PhotoEditService(model: model, listing: listing, space: space)
        let reviewedJobID = photoJobs.visibleJob?.id
        checkingSavedPhoto = true; savedPhotoNote = nil
        Task { @MainActor in
            defer { checkingSavedPhoto = false }
            do {
                try await service.recover(saved)
                guard service.identityIsCurrent else { return }
                savedPhotoNote = "Your saved edit is ready. Open Latest or its edit tab to review it."
                loadExisting()
                dismissRecoveredPhotoReview(reviewedJobID)
            } catch {
                guard service.identityIsCurrent else { return }
                let failure = error as? APIError
                if ["photo_quality_pending", "photo_quality_hold"].contains(failure?.code ?? "") {
                    savedPhotoNote = "Your saved edit is still being reviewed. Check it again later; no new edit was started."
                } else if failure?.status == 404 {
                    savedPhotoNote = "No saved result is available for this request. Nothing was generated or charged by this check. Your request stays saved."
                } else {
                    savedPhotoNote = "The saved edit could not be recovered: " + error.localizedDescription
                }
                refreshSavedPhotoEdits()
            }
        }
    }

    private func dismissRecoveredPhotoReview(_ reviewedJobID: UUID?) {
        guard savedPhotoReadError == nil, savedPhotoEdits.isEmpty,
              let reviewedJobID, let job = photoJobs.visibleJob, job.id == reviewedJobID,
              job.listingID == listing.id, !job.running, !job.failures.isEmpty,
              job.failures.allSatisfy({ failure in
                  AIFailure.requiresSavedPhotoCheck(failure.error)
              }) else { return }
        photoJobs.dismissResult()
    }

    private var studioSpinnerRow: some View {
        HStack(spacing: 8) {
            ProgressView()
            Text(processingText).foregroundStyle(Theme.inkDim)
        }
        .padding(.vertical, 8)
    }

    /// Every photo in the library as ONE share: the export sheet packages
    /// several photos into a single ZIP by default, which is what an agent
    /// can actually hand to the person who runs their file.
    private var shareAllButton: some View {
        Button { exportingPhotos = PhotoExportSelection(photos: libraryPhotos) } label: {
            Label(libraryKind == .latest ? "Share all photos" : "Share all \(libraryKind.rawValue.lowercased()) photos", systemImage: "square.and.arrow.up")
                .font(.rpBody.weight(.semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .modifier(RendpropActionLabelSurface(primary: true))
        }
        .accessibilityIdentifier("photos.shareAll")
        .disabled(libraryPhotos.isEmpty)
    }

    /// The empty library. It says what happens to a photo when it lands,
    /// because "it gets brightened automatically, free" is the reason to put
    /// them here first.
    private var photosEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.stack")
                .font(.system(size: 30, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.white)
                .frame(width: 60, height: 60)
                .background(RPGradient.photo,
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            Text("Add your photos")
                .font(.rpHeadline).foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
            Text("Every photo is brightened and sharpened the moment it lands \u{2014} free, on this phone, no waiting. Then AI Photo Studio can change any of them.")
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 18)
    }

    /// The line above the library grid. Three verbs, all of them free.
    private var photosGridHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(libraryKind == .original ? "Tap the wand to edit an original. Tap a photo to review its saved versions."
                 : "Tap a photo to review, share, or select it for your listing. To try a different edit, return to Original.")
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
                .fixedSize(horizontal: false, vertical: true)
            if libraryKind == .latest { Label("Brightening and sharpening on this phone costs nothing.",
                  systemImage: "sparkles")
                .font(.rpCaption.weight(.semibold))
                .foregroundStyle(Theme.good)
                .fixedSize(horizontal: false, vertical: true) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The door from the library to the studio, on the library screen, named.
    /// The two are siblings in the toolbox; this is the shortcut for someone
    /// already standing in front of their photos.
    private var openStudioCard: some View {
        NavigationLink { PhotoStudioView(listing: listing, entry: .studio) } label: {
            HStack(spacing: 12) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(width: 40, height: 40)
                    .background(RPGradient.photo,
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Edit originals with AI")
                        .font(.rpBody.weight(.semibold)).foregroundStyle(Theme.ink)
                    Text("Declutter \u{00B7} staging \u{00B7} twilight \u{00B7} sky")
                        .font(.rpCaption).foregroundStyle(Theme.inkDim)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.rpCaption.weight(.bold)).foregroundStyle(Theme.inkDim)
            }
            .padding(10)
            .background(Theme.fillSubtle,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(ScalePressStyle())
        .accessibilityIdentifier("photos.openStudio")
    }

    // MARK: - Screen two: AI PHOTO STUDIO
    //
    // MODE FIRST. The screen opens on what the AI can do, in words, with
    // nothing else competing for the first screenful. The photos already
    // uploaded appear only once a mode is chosen - which is the whole point:
    // "pick Declutter, then tick the photos" instead of "here are your photos,
    // now go hunting for the verb".

    private var studioBody: some View {
        VStack(spacing: Theme.spacing) {
            if photos.isEmpty && !isProcessing {
                studioNeedsPhotos
            } else {
                studioReadyStrip
            }

            studioEditSection
            pendingAnimationCard

            if isProcessing && batchRun == nil {
                studioSpinnerRow
            }

            // THE GRID IS ONLY HERE ONCE A MODE IS CHOSEN. An AI screen that
            // opens on a wall of thumbnails is the screen he kept reporting.
            if !photos.isEmpty {
                if batchEdit != nil { studioPickHint }
                else { Text("Review your photos").font(.rpHeadline).foregroundStyle(Theme.ink) }
                photoGrid
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.86), value: batchEdit != nil)
    }

    /// No photos yet. The studio does not pretend it can do anything, and it
    /// names the screen that comes first rather than opening a picker and
    /// hoping.
    private var studioNeedsPhotos: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 30, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.white)
                .frame(width: 60, height: 60)
                .background(RPGradient.photo,
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            Text("Add photos first")
                .font(.rpHeadline).foregroundStyle(Theme.ink)
            Text("Photos live in this home\u{2019}s Photos section \u{2014} they get brightened on the way in. Add them, then pick a change here.")
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            addButton("Add photos", "photo.stack", filled: true) { showLibrary = true }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }

    /// One strip at the top of the studio: your photos are here, this is how
    /// many, this is what happens next. It replaces the grid that used to open
    /// this screen.
    private var studioReadyStrip: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.good)
            VStack(alignment: .leading, spacing: 2) {
                Text(studioReadyTitle)
                    .font(.rpBody.weight(.semibold)).foregroundStyle(Theme.ink)
                Text("Pick a change below, then tick the ones to change.")
                    .font(.rpCaption).foregroundStyle(Theme.inkDim)
                    .lineLimit(2).minimumScaleFactor(0.85)
            }
            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.fillSubtle, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var studioReadyTitle: String {
        "\(photos.count) photo\(photos.count == 1 ? "" : "s") ready"
    }

    /// The line above the grid, in the studio, where the grid means one thing
    /// only: tick the photos this change applies to.
    private var studioPickHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tap the photos you want changed \u{2014} they get a tick. Decluttered and staged versions stay available in Photos. Staging is a preview until you choose it for the listing.")
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
                .fixedSize(horizontal: false, vertical: true)
            Label("Review saved disclosures and retained source photos before publishing. Export includes disclosure captions for your chosen destination.",
                  systemImage: "info.circle")
                .font(.rpCaption.weight(.semibold))
                .foregroundStyle(Theme.good)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var studioSheets: some View {
        studioCore
        .disabled(connection.isWaiting)
        .sessionConnectionNotice(isActive: connection.isWaiting, onCancel: { connection.cancel() })
        .sheet(isPresented: $showLibrary, onDismiss: {
            if libraryImportID == nil { pendingShowcaseEdit = nil; pendingShowcaseStyle = nil }
        }) {
            LibraryImagePicker(onBegin: { id, count, cancellation in
                guard !isProcessing else {
                    photoSaveError = "Another photo is still saving. Please wait, then add those photos again."
                    return false
                }
                libraryImportID = id
                libraryImportCancellation = cancellation
                localProcessing = true
                photoSaveError = nil
                processingText = "Loading \(count) photos from your library…"
                return true
            }, onProgress: { id, completed, total in
                guard libraryImportID == id else { return }
                processingText = "Loading photo \(completed) of \(total)…"
            }, onCancel: {
                pendingShowcaseEdit = nil; pendingShowcaseStyle = nil
            }, onImport: { batch in ingest(batch) }).ignoresSafeArea()
        }
        .sheet(isPresented: $showCaptureGuide, onDismiss: {
            if openCameraAfterGuide { openCameraAfterGuide = false; showCamera = true }
        }) {
            CaptureOrientationGuide(intent: captureIntent, onContinue: {
                openCameraAfterGuide = true; showCaptureGuide = false
            }, onCancel: { openCameraAfterGuide = false; showCaptureGuide = false })
        }
        .fullScreenCover(isPresented: $showCamera) {
            GuidedPhotoCamera(purpose: .interior, captureIntent: captureIntent, onPicked: { img in
                let error = await withCheckedContinuation { continuation in
                    ingest([img]) { continuation.resume(returning: $0) }
                }
                if error == nil { showCamera = false }
                return error
            }, onCancel: { showCamera = false })
            .ignoresSafeArea()
        }
        .fullScreenCover(item: $compare, onDismiss: { loadExisting() }) { presentation in
            PhotoCompareView(photo: presentation.photo, requestedCover: presentation.requestedCover,
                             galleryPhotos: entry == .photos ? galleryFamilyPhotos : [])
        }
        .sheet(item: $stagingSetup) { setup in
            PhotoStagingSetupView(setup: setup) { referenceID, brief in
                stagingSetup = nil
                connection.run {
                    guard setup.isCurrent else { return }
                    startPhotoWork(setup.pending, targets: setup.targets, prompt: brief,
                                   stagingReferenceID: referenceID)
                }
            }
        }
        .sheet(item: $declutterReview) { review in
            PhotoDeclutterReviewSheet(review: review) { targets, approvals in
                declutterReview = nil
                guard review.isCurrent else { return }
                guard !targets.isEmpty else {
                    batchEdit = nil; batchSelection.removeAll()
                    batchNote = BatchNote(text: "Declutter review complete. No image edits were started; originals stay unchanged.", ok: true)
                    return
                }
                startPhotoWork(PendingBatchEdit(edit: "declutter", style: nil, title: "Declutter", multiple: targets.count > 1),
                    targets: targets, prompt: nil, declutterApprovals: approvals)
            }
        }
        .sheet(item: $animatedClip) { clip in AnimatedClipSheet(clip: clip) }
        .sheet(item: $customEditPhoto, onDismiss: { customBatchTargets = [] }) { p in
            CustomEditSheet(photo: p, api: model.api, space: space,
                            listingServerID: listingServerID) { prompt in
                // ONE prompt, one or many photos. `customBatchTargets` is set
                // only by the edit bar's "Ask for anything" → pick photos → Apply
                // path; the wand and the long-press menu leave it empty and get
                // the single-photo behaviour they always had, compare sheet and
                // all. Same endpoint, same `aiEdit`/`performEdit` body, one
                // charge per photo either way.
                let targets = customBatchTargets.isEmpty ? [p] : customBatchTargets
                customBatchTargets = []
                if targets.count == 1 {
                    aiEdit(targets[0], "custom", prompt: prompt)
                } else {
                    runBatch(PendingBatchEdit(edit: "custom", style: nil,
                                              title: EditWords.custom, multiple: true),
                             targets: targets, prompt: prompt)
                }
            }
        }
        .sheet(item: $suggestResult) { r in
            SuggestSheet(suggestions: r.suggestions) { edit in
                // stage needs a style — default to modern (the dialog's first).
                if edit == "stage" { aiEdit(r.photo, "stage", style: "modern") }
                else { aiEdit(r.photo, edit) }
            }
        }
        // NO reel cover here any more. Reel Studio is presented by the LISTING
        // screen's "Make a reel" tile, which is where the aerial intro is handed
        // over as `extraClipURLs` — that fix (the aerial could otherwise only be
        // used as a reel intro from inside the aerial sheet) has moved with it,
        // not been dropped.
    }

    private var photoActionDialogs: some View {
        studioSheets
        // The wand's visible menu — same edits as the long-press path, one tap.
        .confirmationDialog("Change this photo", isPresented: $showWandDialog,
                            titleVisibility: .visible, presenting: wandPhoto) { p in
            Button("✨ \(EditWords.suggest)") { suggestEdits(p) }
            Button(EditWords.twilight) { aiEdit(p, "twilight") }
            Button(EditWords.sky) { aiEdit(p, "sky") }
            if space == .realEstate {
                Button(EditWords.lawn) { aiEdit(p, "lawn") }
            }
            Button(EditWords.declutter) { aiEdit(p, "declutter") }
            Button("\(EditWords.stage(space))…") {
                stagePhoto = p
                // Present after this dialog finishes dismissing.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { showStageDialog = true }
            }
            Button("\(EditWords.custom)…") { openCustomEdit(p) }
            Button(EditWords.animate) { animate(p) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Each edit is saved separately. Find decluttered and staged photos in Photos. Choose a staged preview for the listing only after reviewing it.")
        }
    }

    private var removalDialogs: some View {
        photoActionDialogs
        // Removal hides the family; source bytes remain available to earlier
        // versions and existing reels. Imported galleries preserve cloud photos.
        .confirmationDialog("Remove this photo from the gallery?", isPresented: $showPhotoDeleteConfirm,
                            titleVisibility: .visible, presenting: pendingPhotoDelete) { p in
            Button("Remove from gallery", role: .destructive) {
                delete(p)
                pendingPhotoDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingPhotoDelete = nil }
        } message: { _ in
            if (model.listings.first(where: { $0.id == listing.id }) ?? listing).cloudImported == true {
                Text("This hides the photo family from this iPhone's gallery. Photos already on the published listing remain online. Source files and edit history stay on this phone.")
            } else {
                Text("This removes the photo family from the selected gallery. Your published listing updates when gallery sync finishes. Source files and edit history stay on this phone.")
            }
        }
        .confirmationDialog("Delete this clip?", isPresented: $showClipDeleteConfirm,
                            titleVisibility: .visible, presenting: pendingClipDelete) { clip in
            Button("Delete clip", role: .destructive) {
                deleteClip(clip)
                pendingClipDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingClipDelete = nil }
        } message: { _ in
            Text("Removes the motion clip from this phone. Anything you already saved to Photos or shared stays where it is.")
        }
    }

    private var editFeedbackDialogs: some View {
        removalDialogs
        .confirmationDialog("Pick a style", isPresented: $showStageDialog,
                            titleVisibility: .visible, presenting: stagePhoto) { p in
            Button("Modern") { aiEdit(p, "stage", style: "modern") }
            Button("Rustic") { aiEdit(p, "stage", style: "rustic") }
            Button("Minimalist") { aiEdit(p, "stage", style: "minimalist") }
            Button("Contemporary") { aiEdit(p, "stage", style: "contemporary") }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            // `stagingLabel` is the INDUSTRY term ("Virtual staging" /
            // "Furnish & style") — the button says "Add furniture", the
            // disclosure sentence says what a broker has to read.
            Text("AI adds furniture in the style you pick. Review the result for unwanted changes. Restyling starts from the saved pre-furniture version, so later edits may not carry over. Export includes \(stagingLabel.lowercased()) disclosure text.")
        }
        .alert(aiFailure?.title ?? "That one didn't work",
               isPresented: Binding(get: { aiFailure != nil }, set: { if !$0 { aiFailure = nil } }),
               presenting: aiFailure) { f in
            if f.isQuota {
                // In-app paywall only — no external purchase CTA (3.1.1 / 3.1.3).
                Button("Upgrade plan") {
                    aiFailure = nil
                    PaywallRouter.shared.present(reason: .quota(feature: "photo_edits"))
                }
            }
            if f.isUnauthorized {
                Button("Retry connection") {
                    aiFailure = nil
                    connection.run {}
                }
            }
            if f.isServiceUnavailable || f.isTrialCapacityUnavailable {
                Button("Contact support") {
                    aiFailure = nil
                    UIApplication.shared.open(SettingsView.supportMailURL(subject: "AI edit failed — \(f.title)"))
                }
            }
            Button("OK", role: .cancel) { aiFailure = nil }
        } message: { f in
            Text(f.fullMessage)
        }
    }

    var body: some View {
        editFeedbackDialogs
        .sheet(item: $exportingPhotos) { selection in
            PhotoExportSheet(photos: selection.photos, original: selection.original, archiveName: listing.address,
                             onExported: PhotoFeedbackQueue.recordExport)
        }
        .confirmationDialog("Use the selected version as the listing cover too?", isPresented: $confirmListingCoverFollow, titleVisibility: .visible) {
            Button("Use versions and keep the cover selected") {
                guard listingCoverContext?.isCurrent == true else { listingCoverTargets = []; return }
                changeGridListingChoices(listingCoverTargets, toggling: listingCoverIsToggle, followCover: true, requestedSelection: true)
                listingCoverTargets = []
            }
            Button("Cancel", role: .cancel) { listingCoverTargets = [] }
        } message: {
            Text("One chosen version replaces the current cover photo. Your originals and earlier edits stay saved.")
        }
        // Third-party processing consent is asked at AI entry or immediately
        // before an edit; viewing, importing and exporting ordinary photos
        // remains available without opting into AI processing.
        .aiConsentGate()
        .paywallHost(managesLifecycle: false)
        .onDisappear {
            if !isPresentingOverlay { connection.cancel() }
        }
        .task {
            if entry == .studio, await AIConsent.shared.ensureGranted() == false { dismiss() }
#if targetEnvironment(simulator)
            // Exact offline fixture only: exercise the existing quota alert and
            // its modal paywall host without dispatching an AI job or purchase.
            if Config.isUITesting, ProcessInfo.processInfo.arguments.contains("-ui.photoQuotaFixture"),
               listing.address == "Detail fixture empty", model.api is MockAPIClient {
                aiFailure = AIFailure(APIError.server(status: 402, code: "quota_exceeded", message: "Synthetic photo allowance is used up."))
            }
#endif
        }
    }

    private var photoGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            PhotoOrientationFilterControl(filter: $photoOrientationFilter,
                orientations: libraryPhotos.map(photoOrientation), selectedCount: batchEdit == nil ? nil : batchSelection.count)
                .disabled(listingChoiceWorkID != nil)
            if filteredLibraryPhotos.isEmpty && !libraryPhotos.isEmpty {
                Text("No \(photoOrientationFilter?.rawValue ?? "matching") photos in this view.")
                    .font(.rpCaption).foregroundStyle(Theme.inkDim)
                Button("Show all photos") { photoOrientationFilter = nil }
                    .font(.rpCaption.weight(.semibold)).frame(minHeight: 44)
            }
            if entry == .photos && batchEdit == nil { listingCategoryActions }
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(filteredLibraryPhotos) { p in
                    VStack(alignment: .leading, spacing: 5) {
                        photoCell(p, selectedForListing: listingPhotoSelected(p.id))
                        if entry == .photos && batchEdit == nil { gridListingChoice(p) }
                        Text(photoOrientation(p).label).font(.rpCaption).foregroundStyle(Theme.inkDim)
                            .accessibilityIdentifier("photos.orientation.\(p.id)")
                        if entry == .photos && libraryKind == .staged, let style = p.savedVersion?.style, !style.isEmpty {
                            Text(style.capitalized).font(.rpCaption).foregroundStyle(Theme.inkDim)
                        }
                    }
                }
            }
        }
        .task(id: photoGeometryInputs) {
            let inputs = photoGeometryInputs, actor = auth.userID, revision = auth.syncSessionRevision
            let workspace = WorkspaceContext.selectedOrgID
            let values = await PhotoGeometryReader.observe(inputs)
            guard !Task.isCancelled, photoGeometryInputs == inputs, auth.userID == actor,
                  auth.syncSessionRevision == revision, WorkspaceContext.selectedOrgID == workspace else { return }
            photoOrientations = values
        }
        // Filters never reorder the underlying source list or selection.
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85), value: photos.count)
    }

    private func gridListingTarget(_ photo: EnhancedPhoto) -> PhotoGridListingSelection.Target? {
        photo.savedVersion.map { .init(id: $0.id, familyID: $0.familyID, imageFile: $0.imageFile,
            requiresReview: $0.needsStagingReview || $0.needsCustomReview) }
    }
    private func gridListingState(_ target: PhotoGridListingSelection.Target) -> PhotoGridListingSelection.State {
        PhotoGridListingSelection.state(target, cloud: isCloudPhotoListing,
            projection: model.cloudPhotoProjection(for: listing.id),
            localSelected: publicationLabels[target.id] == nil ? nil : selectedPhotoIDs.contains(target.id),
            saving: listingChoiceIDs.contains(target.id))
    }
    private var listingCategoryActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                let targets = PhotoGridListingSelection.categoryTargets(filteredLibraryPhotos.compactMap(gridListingTarget))
                changeGridListingChoices(targets)
            } label: {
                Label("Select all for listing", systemImage: "checkmark.circle")
                    .font(.rpBody.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(RendpropPillButtonStyle(compact: true))
            .disabled(filteredLibraryPhotos.isEmpty || isProcessing || galleryRetrying || listingChoiceWorkID != nil)
            .accessibilityIdentifier("photos.selectCategoryForListing")
            .accessibilityHint("Uses the latest shown version of each photo. Results still needing review stay unchanged.")
            Text("One shown version per photo. Results needing review or verification stay unchanged.")
                .font(.rpCaption).foregroundStyle(Theme.inkDim).fixedSize(horizontal: false, vertical: true)
            if listingChoiceWorkID != nil {
                Button("Stop selecting") {
                    listingChoiceTask?.cancel()
                    listingChoiceNote = "Stopping. Already saved choices stay selected."
                }.buttonStyle(RendpropPillButtonStyle(compact: true)).frame(minHeight: 44)
            }
            if let listingChoiceNote {
                Text(listingChoiceNote).font(.rpCaption).foregroundStyle(Theme.inkDim)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("photos.listingChoiceStatus")
            }
        }
    }
    @ViewBuilder private func gridListingChoice(_ photo: EnhancedPhoto) -> some View {
        if let target = gridListingTarget(photo) {
            let state = gridListingState(target)
            Button { changeGridListingChoices([target], toggling: true) } label: {
                HStack(spacing: 6) {
                    if state == .saving { ProgressView().controlSize(.small) }
                    else { Image(systemName: state.isSelected ? "checkmark.circle.fill" : state == .reviewRequired ? "checkmark.shield" : state == .unknown || state == .pending ? "arrow.clockwise" : "circle") }
                    Text(state.title).fixedSize(horizontal: false, vertical: true)
                }
                .font(.rpCaption.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(RendpropPillButtonStyle(selected: state.isSelected, compact: true, horizontalPadding: 10))
            .disabled(isProcessing || galleryRetrying || listingChoiceWorkID != nil)
            .accessibilityLabel(state == .selectedNeedsBrowserCopy ? "Prepare this selected version for the website" : state == .selected ? "Remove this version from listing" : state == .available ? "Use this version on listing" : state.title)
            .accessibilityValue(state.value)
            .accessibilityAddTraits(state.isSelected ? .isSelected : [])
            .accessibilityIdentifier("photos.useOnListing." + photo.id)
        } else {
            Button("Check saved version") { compare = PhotoComparePresentation(photo: photo) }
                .buttonStyle(RendpropPillButtonStyle(compact: true, horizontalPadding: 10))
                .frame(minHeight: 44).disabled(isProcessing || listingChoiceWorkID != nil)
                .accessibilityHint("The saved version must be verified before its listing selection can change.")
        }
    }
    private func changeGridListingChoices(_ targets: [PhotoGridListingSelection.Target], toggling: Bool = false, followCover: Bool = false, requestedSelection: Bool? = nil) {
        guard !targets.isEmpty, !isProcessing, !galleryRetrying, listingChoiceWorkID == nil,
              let live = model.listings.first(where: { $0.id == listing.id }), live.cloudUnavailable != true else { return }
        let context = NativeMediaExportContext(), server = live.serverID, physical = live.serverOrgID
        let initialState = toggling ? gridListingState(targets[0]) : nil
        if toggling, initialState == .reviewRequired,
           let photo = filteredLibraryPhotos.first(where: { $0.id == targets[0].id }) {
            compare = PhotoComparePresentation(photo: photo); return
        }
        let workID = UUID(); listingChoiceWorkID = workID; listingChoiceIDs = Set(targets.map(\.id))
        listingChoiceNote = nil; photoSaveError = nil
        listingChoiceTask = Task { @MainActor in
            defer { if listingChoiceWorkID == workID { listingChoiceWorkID = nil; listingChoiceIDs = []; listingChoiceTask = nil } }
            @MainActor func check() throws {
                guard context.isCurrent, !Task.isCancelled,
                      let current = model.listings.first(where: { $0.id == listing.id }), current.cloudUnavailable != true,
                      current.serverID == server, current.serverOrgID == physical else { throw PhotoCloudSelectionFailure.identityChanged }
            }
            @MainActor func version(_ target: PhotoGridListingSelection.Target) throws -> PhotoVersionHistory.Version {
                try check()
                let index = try PhotoVersionHistory.load(directory: dir)
                guard let value = index.versions[target.id], !index.hiddenFamilies.contains(value.familyID),
                      value.familyID == target.familyID, value.imageFile == target.imageFile,
                      (value.needsStagingReview || value.needsCustomReview) == target.requiresReview else { throw PhotoVersionHistory.Failure.changedVersion }
                return value
            }
            @MainActor func currentState(_ target: PhotoGridListingSelection.Target) throws -> PhotoGridListingSelection.State {
                _ = try version(target)
                let local = server == nil ? try PhotoVersionHistory.load(directory: dir).isSelectedForListing(target.id) : nil
                return PhotoGridListingSelection.state(target, cloud: server != nil,
                    projection: model.cloudPhotoProjection(for: listing.id), localSelected: local)
            }
            @MainActor func hasFamilyCover(_ target: PhotoGridListingSelection.Target) -> Bool {
                guard let projection = model.cloudPhotoProjection(for: listing.id) else { return false }
                return projection.versions.contains { $0.familyID == target.familyID && projection.coverVersionIDs.contains($0.id) }
            }
            @MainActor func apply(_ target: PhotoGridListingSelection.Target, selecting: Bool) async throws {
                let value = try version(target)
                guard !selecting || !value.needsStagingReview && !value.needsCustomReview else { throw PhotoVersionHistory.Failure.reviewRequired }
                if server != nil {
                    let current = model.cloudPhotoProjection(for: listing.id)
                    let repairingSelectedCopy = try selecting && currentState(target) == .selectedNeedsBrowserCopy
                    let repairingOwnCover = repairingSelectedCopy && current?.coverVersionIDs.contains(target.id) == true &&
                        current?.versions.filter({ $0.familyID == target.familyID && current?.selectedVersionIDs.contains($0.id) == true }).count == 1
                    _ = try await model.changeCloudPhotoSelection(listingID: listing.id, versionID: target.id,
                        selecting: selecting, followFamilyCover: selecting && ((followCover && hasFamilyCover(target)) || repairingOwnCover),
                        reviewed: !value.needsStagingReview && !value.needsCustomReview, requireSelectedVersion: !selecting,
                        requireCurrentSelection: repairingSelectedCopy)
                    try check()
                } else {
                    let cover = model.listings.first(where: { $0.id == listing.id })?.mainPhotoRelPath
                    let wasCover = try PhotoVersionHistory.familyContains(id: target.id,
                        imageFile: cover.map { FileStore.url(fromRelativePath: $0).lastPathComponent }, directory: dir)
                    if selecting {
                        try PhotoVersionHistory.selectForPublication(id: target.id, directory: dir)
                        if wasCover { model.setMainPhoto(FileStore.relativePath(for: dir.appendingPathComponent(value.imageFile)), for: listing.id) }
                    } else {
                        try PhotoVersionHistory.removeFromPublication(id: target.id, directory: dir)
                        if wasCover {
                            let replacement = try PhotoVersionHistory.availableCoverVersion(directory: dir)
                            model.setMainPhoto(replacement.map { FileStore.relativePath(for: dir.appendingPathComponent($0.imageFile)) }, for: listing.id)
                        }
                    }
                    loadExisting()
                }
            }
            do {
                try check()
                if server != nil { _ = try await model.refreshCloudPhotoSelection(listingID: listing.id); try check() }
                if toggling, requestedSelection == nil, initialState == .unknown || initialState == .pending {
                    let checked = try currentState(targets[0])
                    guard checked != .pending else { throw PhotoCloudSelectionFailure.pending }
                    guard checked != .unknown else { throw PhotoCloudSelectionFailure.unmapped }
                    listingChoiceNote = "Listing selection checked. No photo choice was changed."; return
                }
                let coverChanges = try targets.filter { try currentState($0) == .available && hasFamilyCover($0) }
                if !followCover, !coverChanges.isEmpty {
                    listingCoverTargets = targets; listingCoverContext = context; listingCoverIsToggle = toggling
                    confirmListingCoverFollow = true; return
                }
                if toggling {
                    let state = try currentState(targets[0]), selecting = requestedSelection ?? (initialState != .selected)
                    if initialState == .selectedNeedsBrowserCopy, !state.isSelected { throw PhotoVersionHistory.Failure.changedVersion }
                    if !selecting, !state.isSelected { throw PhotoVersionHistory.Failure.changedVersion }
                    if selecting, state == .reviewRequired { throw PhotoVersionHistory.Failure.reviewRequired }
                    guard state == .available || state.isSelected else { throw PhotoCloudSelectionFailure.unmapped }
                    if selecting != state.isSelected || (selecting && state == .selectedNeedsBrowserCopy) { try await apply(targets[0], selecting: selecting) }
                    let finalState = try currentState(targets[0])
                    guard selecting ? finalState == .selected : (finalState == .available || finalState == .reviewRequired) else { throw PhotoCloudSelectionFailure.changed }
                    listingChoiceNote = selecting ? "This version is selected for the listing." : "This photo is no longer selected for the listing."
                } else {
                    let (report, error) = await PhotoGridListingSelection.selectAll(targets, requireCurrent: check, state: currentState, select: { try await apply($0, selecting: true) })
                    try check()
                    listingChoiceNote = "\(report.selected) selected · \(report.unchanged) already on listing · \(report.needsReview) need review."
                    if let error { photoSaveError = "\(report.selected) choices confirmed. Further selection stopped. " + error.localizedDescription }
                }
            } catch { if context.isCurrent { photoSaveError = error.localizedDescription } }
        }
    }

    /// One thumb, in whichever of the grid's TWO modes is live.
    ///
    /// Normal: tap opens before/after, long-press opens the menu, and the wand
    /// sits in the corner — all exactly as before, because the wand is a good
    /// shortcut and nothing about it needed fixing.
    ///
    /// Selection: an edit from the bar is waiting for its targets, so a tap
    /// ticks the photo instead. The wand is not drawn — a tap that changes one
    /// photo while the screen is asking which photos to change is a trap.
    @ViewBuilder private func photoCell(_ p: EnhancedPhoto, selectedForListing: Bool) -> some View {
        // Wand overlay is a SIBLING of the thumb button (a Button
        // inside another Button's label never gets the tap).
        ZStack(alignment: .bottomTrailing) {
            if batchEdit == nil {
                Button { compare = PhotoComparePresentation(photo: p) } label: {
                    thumb(p, selectedForListing: entry == .photos && selectedForListing,
                          publicationLabel: entry == .photos ? listingPhotoLabel(p.id) : nil)
                        .overlay { busyOverlay(p) }
                }
                    .buttonStyle(ScalePressStyle())
                    .accessibilityLabel(Text(busyPhotoIDs.contains(p.id)
                                             ? "Photo — the AI is working on this one"
                                             : "Photo — opens before-and-after compare"))
                    .accessibilityValue(entry == .photos
                                        ? (listingPhotoLabel(p.id) ?? "Selection unavailable") : "")
                    .accessibilityIdentifier("photos.version.\(p.id)")
                    .contextMenu { photoMenu(p) }
                if !busyPhotoIDs.contains(p.id), entry != .photos || libraryKind == .original { wandButton(p) }
                // THE COVER, on the surface. It was a long-press and nothing
                // else — an invisible gesture for the one picture that
                // represents the whole home everywhere it is shared. Only on
                // the library screen: in the studio a tap means "include this
                // photo in the change", and a second meaning on the same
                // thumbnail is a trap.
                if entry == .photos { coverButton(p) }
            } else {
                Button { toggleBatchSelection(p) } label: {
                    thumb(p).overlay { selectionOverlay(p) }
                }
                .buttonStyle(ScalePressStyle())
                .disabled(isProcessing)
                .accessibilityLabel(Text(batchSelection.contains(p.id)
                                         ? "Photo, selected. Tap to leave it out."
                                         : "Photo, not selected. Tap to include it."))
            }
        }
    }

    /// "This one, right now." Drawn ON the photo because that is where the
    /// agent is looking after they tap the wand on it.
    @ViewBuilder private func busyOverlay(_ p: EnhancedPhoto) -> some View {
        if busyPhotoIDs.contains(p.id) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.45))
                .overlay {
                    VStack(spacing: 6) {
                        ProgressView().tint(Color.white)
                        Text("Working…")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.white)
                    }
                }
                .transition(.opacity)
        }
    }

    /// "Is it doing anything at all?" — answerable without scrolling.
    ///
    /// The top safe-area inset reserves this status capsule's actual height,
    /// including larger text, so it stays visible without covering the grid.
    @ViewBuilder private var workingPill: some View {
        if isProcessing || batchRun != nil {
            HStack(spacing: 8) {
                ProgressView().tint(Color.white)
                Text(pillText)
                    .font(.rpCaption.weight(.semibold))
                    .foregroundStyle(Color.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color.black.opacity(0.82), in: Capsule())
            .shadow(color: Color.black.opacity(0.3), radius: 10, y: 4)
            .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            .allowsHitTesting(false)
            .accessibilityLabel(Text(pillText))
        }
    }

    /// A batch says which photo of how many; a single edit says what it is
    /// doing. Never a bare "Loading" — the agent is paying per photo and is
    /// owed a count.
    private var pillText: String {
        if let run = batchRun {
            return "\(run.phase.title) · photo \(min(run.current, run.total)) of \(run.total)"
        }
        return processingText
    }

    /// The tick (and the dimming) on a photo while an edit picks its targets.
    private func selectionOverlay(_ p: EnhancedPhoto) -> some View {
        let selected = batchSelection.contains(p.id)
        return RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.black.opacity(selected ? 0 : 0.35))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? Theme.accent : Color.clear, lineWidth: 3)
            )
            .overlay(alignment: .topTrailing) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.white, selected ? Theme.accent : Color.black.opacity(0.35))
                    .padding(8)
            }
    }

    @ViewBuilder private func photoMenu(_ p: EnhancedPhoto) -> some View {
        if entry != .photos || libraryKind == .original {
        Menu {
            Button { aiEdit(p, "twilight") } label: { Label(EditWords.twilight, systemImage: "moon.stars") }
            Button { aiEdit(p, "sky") } label: { Label(EditWords.sky, systemImage: "cloud.sun") }
            if space == .realEstate {
                Button { aiEdit(p, "lawn") } label: { Label(EditWords.lawn, systemImage: "leaf") }
            }
            Button { aiEdit(p, "declutter") } label: { Label(EditWords.declutter, systemImage: "sparkles.rectangle.stack") }
            Menu {
                Button { aiEdit(p, "stage", style: "modern") } label: { Text("Modern") }
                Button { aiEdit(p, "stage", style: "rustic") } label: { Text("Rustic") }
                Button { aiEdit(p, "stage", style: "minimalist") } label: { Text("Minimalist") }
                Button { aiEdit(p, "stage", style: "contemporary") } label: { Text("Contemporary") }
            } label: {
                Label(EditWords.stage(space), systemImage: "sofa")
            }
            Button { openCustomEdit(p) } label: { Label("\(EditWords.custom)…", systemImage: "text.bubble") }
        } label: {
            Label("Change this photo", systemImage: "wand.and.stars")
        }
        Button { animate(p) } label: {
            Label(EditWords.animate, systemImage: "play.rectangle.on.rectangle")
        }
        }
        Button { setMain(p) } label: {
            Label("Use as cover photo", systemImage: "star")
        }
        Button { exportingPhotos = PhotoExportSelection(photos: [p]) } label: {
            Label("Export photo", systemImage: "square.and.arrow.up")
        }
        Button(role: .destructive) { confirmDelete(p) } label: {
            Label("Remove from gallery", systemImage: "trash")
        }
    }

    // MARK: - AI calls (await an anonymous or identified workspace session)

    private func runPhotoAI(_ action: @escaping () -> Void) {
        let context = NativeMediaExportContext()
        Task { @MainActor in
            guard await AIConsent.shared.ensureGranted(), context.isCurrent else { return }
            connection.run {
                guard context.isCurrent, AIConsent.shared.isGranted else { return }
                action()
            }
        }
    }

    private func openCustomEdit(_ p: EnhancedPhoto, batchTargets: [EnhancedPhoto] = []) {
        runPhotoAI {
            // Park the batch only after connection succeeds. Cancelling the
            // wait cannot leak these targets into the next single-photo edit.
            customBatchTargets = batchTargets
            customEditPhoto = p
        }
    }

    /// AI edit (twilight | sky | lawn | declutter | stage | custom) via the
    /// `ai-photo` edge function, for ONE photo, opening the before/after when it
    /// lands. `style` rides along for stage, `prompt` for custom. One job at a
    /// time (re-entrancy guard, F-A-22).
    ///
    /// This is now a thin shell around `performEdit`, which is the same body it
    /// always had. The split exists so the edit bar's "apply to these photos"
    /// path can run the IDENTICAL code once per photo instead of inventing a
    /// batch endpoint or a second billing path. Nothing about a single edit
    /// changed: the guard, the session check, the spinner text, the success
    /// haptic and the compare sheet are all still here, in this order.
    private func aiEdit(_ p: EnhancedPhoto, _ edit: String,
                        style: String? = nil, prompt: String? = nil) {
        guard !isProcessing else { return }
        if edit == "stage" {
            runPhotoAI {
                openStagingSetup(PendingBatchEdit(edit: edit, style: style, title: "Staging", multiple: false), targets: [p])
            }
            return
        }
        runPhotoAI { aiEditWithSession(p, edit, style: style, prompt: prompt) }
    }

    private func aiEditWithSession(_ p: EnhancedPhoto, _ edit: String,
                                   style: String?, prompt: String?) {
        let title = edit == "declutter" ? "Declutter" : "Photo edit"
        startPhotoWork(PendingBatchEdit(edit: edit, style: style, title: title, multiple: false),
                       targets: [p], prompt: prompt)
    }

    private func startPhotoWork(_ pending: PendingBatchEdit, targets: [EnhancedPhoto], prompt: String?,
                                stagingReferenceID: String? = nil, declutterApprovals: [String: DeclutterGenerationApproval]? = nil) {
        guard !isProcessing, AIConsent.shared.isGranted else { return }
        if pending.edit == "declutter", declutterApprovals == nil {
            declutterReview = PhotoDeclutterReviewModel(model: model, listing: listing, photos: targets, space: space)
            return
        }
        let service = PhotoEditService(model: model, listing: listing, space: space)
        if service.start(title: pending.title, photos: targets, edit: pending.edit,
                         style: pending.style, prompt: prompt, stagingReferenceID: stagingReferenceID,
                         declutterApprovals: declutterApprovals) {
            batchNote = nil; batchEdit = nil; batchSelection.removeAll()
            Haptics.selection()
        }
    }

    private func receivePhotoWork(_ job: PhotoWorkQueue.Job?) {
        guard let job, job.listingID == listing.id else { batchRun = nil; busyPhotoIDs.removeAll(); return }
        busyPhotoIDs = job.currentPhotoID.map { Set([$0]) } ?? []
        if job.running {
            batchRun = BatchRun(title: job.title, total: job.total, current: job.current,
                                done: job.done, failed: job.failures.count, phase: job.phase ?? .preparing)
            return
        }
        batchRun = nil
        loadExisting()
        guard handledPhotoJob != job.id else { return }
        handledPhotoJob = job.id
        if let error = job.failures.first?.error, AIFailure.requiresSavedPhotoCheck(error) {
            batchNote = BatchNote(text: "The result is not confirmed. Your request is retained. In Photos, use Check saved edit instead of starting another edit.", ok: false)
            return
        }
        let failure = job.failures.first.map { AIFailure($0.error) }
        let pending = PendingBatchEdit(edit: "", style: nil, title: job.title, multiple: true)
        finishBatch(pending, total: job.total, done: job.done, failed: job.failures.count,
                    firstFailure: failure, stoppedEarly: job.interrupted)
        if job.interrupted && job.failures.isEmpty {
            batchNote = BatchNote(text: "\(job.done) of \(job.total) photos changed. Work stopped; saved photos and originals are safe. Reopen the app and select the remaining photos to continue.", ok: false)
        }
    }

    /// The label the public disclosure line carries for a studio edit. Studio
    /// photos have no room names, so the label names the CHANGE — which is what
    /// a broker scanning the audit log needs, and it is never null (a null label
    /// would fall back to the bare kind on the hosted page).
    static func provenanceLabel(edit: String, style: String?, space: SpaceType) -> String {
        let staging = space == .realEstate ? "Virtual staging" : "Furnish & style"
        switch edit {
        case "twilight":  return "Twilight sky"
        case "sky":       return "Blue sky"
        case "lawn":      return "Green lawn"
        case "declutter": return "Declutter"
        case "stage":
            guard let style, !style.isEmpty else { return staging }
            return "\(staging) — \(style.prefix(1).uppercased() + style.dropFirst())"
        case "custom":    return "Custom edit"
        default:          return "Photo edit"
        }
    }

    /// Ask the AI which preset edits would most improve this photo
    /// (`POST /ai-photo`, edit: "suggest"). Results open in SuggestSheet;
    /// tapping one runs the normal aiEdit path.
    private func suggestEdits(_ p: EnhancedPhoto) {
        guard !isProcessing else { return }
        runPhotoAI { suggestEditsWithSession(p) }
    }

    private func suggestEditsWithSession(_ p: EnhancedPhoto) {
        guard !isProcessing else { return }
        localProcessing = true
        processingText = "Looking at your photo…"
        Haptics.selection()
        let api = model.api          // snapshot on the main actor
        let source = p.enhancedURL
        Task {
            do {
                guard let b64 = await AIImagePrep.jpegBase64(at: source, maxDimension: 1024, quality: 0.8) else {
                    throw AIImagePrep.error("Couldn't read that photo.")
                }
                let results = try await api.aiPhotoSuggest(imageBase64: b64, mime: "image/jpeg")
                await MainActor.run {
                    localProcessing = false
                    suggestResult = SuggestResult(photo: p, suggestions: results)
                    Haptics.success()
                }
            } catch {
                await MainActor.run {
                    localProcessing = false
                    aiFailure = AIFailure(error, title: "Couldn't analyze the photo")
                }
            }
        }
    }

    /// Animate a photo into a short AI motion clip (Seedance image-to-video via
    /// the `ai-video` edge function): downscale → base64 → submit → poll every
    /// 6 s → download the mp4 into this listing's Photos dir → offer save/share.
    /// fal result URLs expire, so the download happens immediately on completion.
    private func animate(_ p: EnhancedPhoto) {
        guard !isProcessing else { return }
        runPhotoAI { animateWithSession(p) }
    }

    private func animateWithSession(_ p: EnhancedPhoto) {
        guard !isProcessing else { return }
        localProcessing = true
        processingText = "Checking your saved video request…"
        Haptics.selection()
        let api = model.api
        let targetDir = dir, source = p.enhancedURL, photoID = p.id
        let listingLocalID = listing.id, isSample = listing.isSample
        let animationOwner = auth.userID, animationRevision = auth.syncSessionRevision
        let animationLibrary = WorkspaceContext.selectedOrgID
        let animationConsentRevision = AIConsent.shared.revocationRevision
        let requireCurrent: @MainActor () throws -> Void = { [auth, model] in
            try Task.checkCancellation()
            guard AIConsent.shared.isGranted,
                  AIConsent.shared.revocationRevision == animationConsentRevision,
                  auth.userID == animationOwner, auth.syncSessionRevision == animationRevision,
                  WorkspaceContext.selectedOrgID == animationLibrary,
                  let current = model.listings.first(where: { $0.id == listingLocalID }),
                  model.isInSelectedWorkspace(current), current.cloudUnavailable != true else { throw CancellationError() }
        }
        let spaceRawForDrift = space.rawValue
        busyPhotoIDs.insert(photoID)
        animateTask = Task {
            defer {
                busyPhotoIDs.remove(photoID)
                localProcessing = false
                refreshSavedAnimations()
            }
            do {
                try requireCurrent()
                guard let animationOwner, !animationOwner.isEmpty else { throw PhotoAnimationRecovery.Failure.unavailable }
                let sourceSHA = PhotoAnimationRecovery.digest(try Data(contentsOf: source, options: .mappedIfSafe))
                guard let b64 = await AIImagePrep.jpegBase64(at: source, maxDimension: 1280, quality: 0.85),
                      let jpeg = Data(base64Encoded: b64), !jpeg.isEmpty else {
                    throw AIImagePrep.error("Couldn't read that photo.")
                }
                try requireCurrent()
                // Generated motion retains this exact source version and account.
                var serverListingID: UUID? = nil
                if !isSample { serverListingID = await model.serverListingIDForCompliance(listingLocalID) }
                try requireCurrent()
                guard isSample || serverListingID != nil else {
                    throw AIImagePrep.error("Reconnect this home's listing before making a video. No generation was started.")
                }
                guard PhotoAnimationRecovery.digest(try Data(contentsOf: source, options: .mappedIfSafe)) == sourceSHA else {
                    throw PhotoAnimationRecovery.Failure.unavailable
                }
                let context = PhotoAnimationRecovery.Context(actor: animationOwner, library: animationLibrary,
                    listing: listingLocalID, serverListing: serverListingID, photoVersion: photoID,
                    sourceFile: source.lastPathComponent, sourceSHA256: sourceSHA, spaceType: spaceRawForDrift)
                let dest = try await PhotoAnimationRecovery.run(context: context, directory: targetDir,
                    prepare: { jpeg }, requireCurrent: requireCurrent,
                    submit: { bytes, operationID in
                        processingText = "Making your video…"
                        return try await api.aiVideoReelClip(imageBase64: bytes.base64EncodedString(), mime: "image/jpeg",
                            prompt: nil, seconds: 5, listingServerID: serverListingID,
                            label: "Animated photo", idempotencyKey: operationID)
                    }, poll: { job in
                        processingText = "Checking your saved video…"
                        return try await api.aiVideoStatus(job)
                    }, download: { url in
                        let (file, response) = try await URLSession.shared.download(from: url)
                        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                            try? FileManager.default.removeItem(at: file)
                            throw AIImagePrep.error("The saved video could not be downloaded. Check this same request again; no new generation will be started.")
                        }
                        return file
                    }, judge: { job, bytes, clip, markDispatched in
                        processingText = "Checking it against your photo…"
                        let frames = await ClipFrames.extract(from: clip)
                        try requireCurrent()
                        guard frames.count == 3 else {
                            return DriftVerdict(status: .unavailable, publishable: false, action: "hold",
                                message: "The saved video could not be decoded for quality review.", reason: "no_frames")
                        }
                        try markDispatched() // Durable marker only at the paid QC seam, after local frame extraction.
                        return try await api.aiVideoDrift(DriftCheckRequest(requestID: job.requestId, kind: "reel",
                            sourceBase64: bytes.base64EncodedString(), frames: frames, seconds: 5,
                            spaceType: spaceRawForDrift, listingServerID: serverListingID, provenanceID: job.provenanceID))
                    }, lookup: { operationID, listingID in
                        try await api.aiVideoOperation(operationID: operationID, listingServerID: listingID)
                    }, validateSource: {
                        guard PhotoAnimationRecovery.digest(try Data(contentsOf: source, options: .mappedIfSafe)) == sourceSHA else {
                            throw PhotoAnimationRecovery.Failure.unavailable
                        }
                    })
                try requireCurrent()
                guard PhotoAnimationRecovery.digest(try Data(contentsOf: source, options: .mappedIfSafe)) == sourceSHA else {
                    throw PhotoAnimationRecovery.Failure.unavailable
                }
                clips = SavedClip.loadAll(listingID: listingLocalID)
                animatedClip = AnimatedClip(url: dest)
                Haptics.success()
            } catch is CancellationError {
                // Leaving stops this phone's work, never erases its paid receipt.
            } catch {
                guard (try? requireCurrent()) != nil else { return }
                aiFailure = AIFailure(error, title: "Saved photo video")
            }
        }
    }

    private func refreshSavedAnimations() {
        guard let owner = auth.userID else { savedAnimations = []; return }
        savedAnimations = PhotoAnimationRecovery.pending(directory: dir, actor: owner,
            library: WorkspaceContext.selectedOrgID, listing: listing.id)
    }

    @ViewBuilder private var pendingAnimationCard: some View {
        if !savedAnimations.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Saved photo videos").font(.rpHeadline).foregroundStyle(Theme.ink)
                Text("Check the same saved request. This does not start another generation.")
                    .font(.rpCaption).foregroundStyle(Theme.inkDim)
                ForEach(savedAnimations, id: \.operationID) { saved in
                    SecondaryButton(title: "Check saved video", systemImage: "arrow.clockwise",
                                    isDisabled: isProcessing, isCompact: true) {
                        let candidates = photos + photos.flatMap(\.history)
                        guard let photo = candidates.first(where: {
                            $0.id == saved.context.photoVersion && $0.enhancedURL.lastPathComponent == saved.context.sourceFile
                        }) else {
                            aiFailure = AIFailure(PhotoAnimationRecovery.Failure.unavailable, title: "Saved photo video")
                            return
                        }
                        animate(photo)
                    }.accessibilityIdentifier("photos.savedAnimation.\(saved.operationID.uuidString)")
                }
            }.frame(maxWidth: .infinity, alignment: .leading).card()
        }
    }

    // MARK: - Pieces

    private func thumb(_ p: EnhancedPhoto, selectedForListing: Bool = false, publicationLabel: String? = nil) -> some View {
        DetailPhotoThumb(url: p.enhancedURL, height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border))
            .overlay(alignment: .topLeading) {
                PhotoPublicationBadges(isCover: isMain(p), publicationLabel: publicationLabel,
                                       photoID: p.id, selectedForListing: selectedForListing)
            }
    }

    private func addButton(_ title: String, _ icon: String, filled: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.rpBody.weight(.semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 13)
                .modifier(RendpropActionLabelSurface(primary: filled))
        }
    }

    // MARK: - Studio identity + the reel card
    //
    // Every piece below is its own tiny sub-view on purpose: this file has hit
    // the type-checker's expression budget before, and `studioCore` must stay
    // a short list of identifiers.

    /// Nav-bar title + subtitle. iOS 16 has no `navigationSubtitle`, so the two
    /// lines are a principal toolbar item: WHAT this screen is, and WHICH
    /// home's studio you are standing in.
    private var studioTitleBar: some View {
        VStack(spacing: 1) {
            Text(entry == .photos ? "Photos · \(galleryFamilyPhotos.count)" : "AI Photo Studio")
                .accessibilityIdentifier("photos.libraryCount")
                .font(.rpBody.weight(.semibold))
                .foregroundStyle(Theme.ink)
            Text(studioSubtitle)
                .font(.caption2)
                .foregroundStyle(Theme.inkDim)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    /// The home this studio belongs to — its address, or the space's own name
    /// when there is no address yet. Never blank.
    private var studioSubtitle: String {
        let address = listing.address.trimmingCharacters(in: .whitespacesAndNewlines)
        return address.isEmpty ? "This \(space.spaceNoun)" : address
    }

    // `canMakeReel`, `reelCard`, `reelCardFace`, `reelCardHeader` and
    // `reelVoiceCallout` were all deleted from here.
    //
    // They existed for ONE reason: the listing screen's "Make a reel" tile was
    // `NavigationLink { PhotoStudioView(listing:, intent: .reel) }`, so the reel
    // journey ran through AI Photo Studio and needed a door at the far end —
    // and the highlight ring on that door (`intent == .reel`) was there to tell
    // the agent that the screen they had landed on was not the screen they
    // asked for. The tile presents `ReelStudioView` itself now, so the door,
    // the ring and the intent that drove it are all gone. Reels are not a photo
    // editing feature and they no longer take up room on the photo editing
    // screen.
    //
    // The reel's own copy is NOT lost — "Make a reel", "Video + your voice" and
    // the voice/captions promise live on the listing tile and inside Reel
    // Studio's own steps.

    /// Motion clips already generated for this listing (F-A-23). Before this,
    /// an "Animate" result was reachable exactly once — the file stayed on the
    /// phone forever with no way to open, share or delete it.
    @ViewBuilder private var clipsCard: some View {
        if !clips.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("MOTION CLIPS").font(.rpKicker).foregroundStyle(Theme.inkDim)
                    Spacer(minLength: 8)
                    Text("\(clips.count)")
                        .font(.rpCaption).foregroundStyle(Theme.inkDim)
                }
                ForEach(clips) { clip in
                    Button {
                        animatedClip = AnimatedClip(url: clip.url)
                        Haptics.selection()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "play.rectangle.on.rectangle")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Color.white)
                                .frame(width: 40, height: 40)
                                .background(RPGradient.reel,
                                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Motion clip")
                                    .font(.rpBody.weight(.semibold))
                                    .foregroundStyle(Theme.ink)
                                Text(clip.createdAt == .distantPast
                                     ? "Saved on this phone"
                                     : clip.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.rpCaption).foregroundStyle(Theme.inkDim)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.rpCaption.weight(.bold)).foregroundStyle(Theme.inkDim)
                        }
                        .padding(10)
                        .background(Theme.fillSubtle,
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(ScalePressStyle())
                    .accessibilityLabel(Text("Motion clip — opens save and share"))
                    .contextMenu {
                        Button(role: .destructive) {
                            pendingClipDelete = clip
                            showClipDeleteConfirm = true
                        } label: {
                            Label("Delete clip", systemImage: "trash")
                        }
                    }
                }
                Text("Made with AI motion — the photo itself is unchanged. Long-press a clip to delete it.")
                    .font(.rpCaption).foregroundStyle(Theme.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
    }

    /// Make this photo the cover, from the grid, in one tap. Filled star on
    /// the one that already is — so the control is also the indicator, and a
    /// glance at the grid answers "which one is the cover?" without counting
    /// badges.
    private func coverButton(_ p: EnhancedPhoto) -> some View {
        let isCover = isMain(p)
        return VStack {
            Spacer(minLength: 0)
            HStack {
                Button {
                    guard !isCover else { return }
                    setMain(p)
                } label: {
                    Image(systemName: isCover ? "star.fill" : "star")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isCover ? Color.white : Color.white.opacity(0.9))
                        .frame(width: 32, height: 32)
                        .background(isCover ? Theme.accent : Color.black.opacity(0.42), in: Circle())
                        .shadow(color: Color.black.opacity(0.25), radius: 4, x: 0, y: 2)
                }
                .buttonStyle(ScalePressStyle())
                .padding(8)
                .disabled(isProcessing || galleryRetrying || isCover)
                .accessibilityLabel(Text(isCover ? "This is the cover photo"
                                                 : "Make this the cover photo"))
                .accessibilityIdentifier("photos.cover.\(p.id)")
                Spacer(minLength: 0)
            }
        }
    }

    /// The visible AI entry point on every thumb — opens the same edits as the
    /// long-press menu, no long-press required.
    private func wandButton(_ p: EnhancedPhoto) -> some View {
        Button {
            wandPhoto = p
            showWandDialog = true
            Haptics.selection()
        } label: {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(width: 32, height: 32)
                .background(RPGradient.photo, in: Circle())
                .shadow(color: Color.black.opacity(0.25), radius: 4, x: 0, y: 2)
        }
        .buttonStyle(ScalePressStyle())
        .padding(8)
        .disabled(isProcessing)
        .accessibilityLabel(Text("Change this photo with AI"))
    }

    /// The empty state, now that the edit bar above it carries the names. It is
    /// a prompt to add a photo and nothing else — the menu of what the AI can do
    /// moved OUT of here, permanently, because being reachable only from here is
    /// exactly the defect (see `studioEditSection`).
    private var emptyShowcase: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.stack")
                .font(.system(size: 30, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.white)
                .frame(width: 60, height: 60)
                .background(RPGradient.photo,
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            Text("Add a photo")
                .font(.rpHeadline).foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
            Text("Every change above works the moment you have one. Tap a change now and it picks the photo first.")
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 18)
    }

    // MARK: - The always-on edit bar
    //
    // Every piece below is its own small sub-view. This file has hit the
    // type-checker's expression budget before ("unable to type-check this
    // expression in reasonable time") and `studioCore` must stay a short list of
    // identifiers, so nothing here nests more than it has to.

    /// Everything the AI can do to a photo, NAMED, above the grid, at every
    /// photo count. Plus the selection bar and progress card the batch path
    /// needs — bundled into one `studioCore` child on purpose (its VStack is
    /// already close to `ViewBuilder`'s ten-child limit).
    @ViewBuilder private var studioEditSection: some View {
        VStack(spacing: 10) {
            editBarCard
            stagingCard
            if let pending = batchEdit {
                batchSelectionBar(pending)
            }
            if let run = batchRun {
                batchProgressCard(run)
            }
            if let note = batchNote, batchRun == nil {
                batchNoteCard(note)
            }
        }
    }

    /// The named edits. One tap each — with photos on screen it asks WHICH
    /// photos; with an empty studio it opens the picker and applies the edit to
    /// the photo that lands (`startShowcaseEdit`).
    private var editBarCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("CHANGE YOUR PHOTOS").font(.rpKicker).foregroundStyle(Theme.inkDim)
                Spacer(minLength: 8)
                if !photos.isEmpty {
                    Text("\(photos.count) photo\(photos.count == 1 ? "" : "s")")
                        .font(.rpCaption).foregroundStyle(Theme.inkDim)
                }
            }
            editChipGrid
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    /// The chips themselves. `lawn` is real-estate only — a gym never sees
    /// "green lawn" (P2-4) — and everything else is offered to every trade,
    /// INCLUDING "Ask for anything", which used to be hidden from real estate
    /// for no reason an agent with an odd request would accept.
    private var studioChoiceColumns: [GridItem] {
        dynamicTypeSize.isAccessibilitySize
            ? [GridItem(.flexible())]
            : [GridItem(.adaptive(minimum: 152), spacing: 8)]
    }

    private var editChipGrid: some View {
        LazyVGrid(columns: studioChoiceColumns, spacing: 8) {
            editChip("sparkles.rectangle.stack.fill", EditWords.declutter, "declutter",
                     sub: EditWords.declutterGloss)
            editChip("moon.stars.fill", EditWords.twilight, "twilight")
            editChip("cloud.sun.fill", EditWords.sky, "sky")
            if space == .realEstate {
                editChip("leaf.fill", EditWords.lawn, "lawn")
            }
            editChip("text.bubble.fill", EditWords.custom, "custom")
            editChip("play.rectangle.on.rectangle.fill", EditWords.animate, "animate",
                     multiple: false)
        }
    }

    /// STAGING, by its own name, with all four styles on the surface.
    ///
    /// Before this the word "staging" appeared nowhere an agent could see:
    /// `EditWords.stage(.realEstate)` returns "Add furniture", and Modern /
    /// Rustic / Minimalist / Contemporary live one confirmation dialog behind
    /// another one. Two nested dialogs is not discoverable — the owner reported
    /// virtual staging missing right beside Declutter. The heading is the
    /// industry word, the line under it is the plain-words gloss (never instead
    /// of the word), and the styles are buttons you can read without tapping
    /// anything.
    private var stagingCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sofa.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Theme.accent)
                Text(EditWords.staging(space).uppercased())
                    .font(.rpKicker).foregroundStyle(Theme.inkDim)
                Spacer(minLength: 8)
            }
            Text(EditWords.stagingGloss(space))
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
                .fixedSize(horizontal: false, vertical: true)
            stagingStyleGrid
            Text("Exports include \(stagingLabel.lowercased()) disclosure text. Review your tour’s disclosures before publishing.")
                .font(.caption2).foregroundStyle(Theme.inkDim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var stagingStyleGrid: some View {
        LazyVGrid(columns: studioChoiceColumns, spacing: 8) {
            ForEach(StagingStyle.all) { style in
                stagingStyleChip(style)
            }
        }
    }

    private func stagingStyleChip(_ style: StagingStyle) -> some View {
        let selected = batchEdit?.edit == "stage" && batchEdit?.style == style.id
        return Button { startEdit("stage", style: style.id, title: "\(EditWords.staging(space)) · \(style.label)") } label: {
            HStack(spacing: 8) {
                Text(style.label)
                    .font(.rpCaption.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.accent).accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(RendpropPillButtonStyle(selected: selected, compact: true, horizontalPadding: 12))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .disabled(isProcessing)
        .accessibilityLabel(Text("\(style.label) — pick the photos and the furniture is added to each one."))
    }

    /// One named edit.
    ///
    /// This was `showcaseChip`, and the previous fix already made it a real
    /// `Button` instead of a decoration. That was necessary and not sufficient:
    /// it stayed inside `emptyShowcase`, behind `if photos.isEmpty`, so an agent
    /// with 17 photos on the listing still saw none of these words. `sub` is the
    /// plain-words gloss UNDER the feature's real name, never instead of it
    /// (see `EditWords.declutter`).
    private func editChip(_ icon: String, _ label: String, _ edit: String,
                          sub: String? = nil, multiple: Bool = true) -> some View {
        let selected = batchEdit?.edit == edit && batchEdit?.style == nil
        return Button { startEdit(edit, style: nil, title: label, multiple: multiple) } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.rpCaption.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if let sub {
                        Text(sub)
                            .font(.caption2)
                            .foregroundStyle(Theme.inkDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.accent).accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(RendpropPillButtonStyle(selected: selected, compact: true, horizontalPadding: 12))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .disabled(isProcessing)
        .accessibilityLabel(Text(photos.isEmpty
                                 ? "\(label). Pick a photo and this change is made to it."
                                 : "\(label). Pick the photos and this change is made to each one."))
        .accessibilityIdentifier("studio.edit.\(edit)")
    }

    // MARK: - Choosing which photos an edit applies to

    /// The bar that appears once an edit is chosen and there are photos to
    /// choose from. Tap thumbs in the grid, then Apply.
    private func batchSelectionBar(_ pending: PendingBatchEdit) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(pending.multiple
                 ? "Tap the photos to change, then apply."
                 : "Tap the photo to use.")
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
            HStack(spacing: 8) {
                Text(pending.title)
                    .font(.rpBody.weight(.semibold)).foregroundStyle(Theme.ink)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 8)
                Text("\(batchSelection.count) selected")
                    .font(.rpCaption.weight(.semibold))
                    .foregroundStyle(batchSelection.isEmpty ? Theme.inkDim : Theme.accent)
            }
            batchSelectionButtons(pending)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func batchSelectionButtons(_ pending: PendingBatchEdit) -> some View {
        HStack(spacing: 8) {
            if pending.multiple {
                // `label:` form rather than `Button(<ternary of literals>)`:
                // `Button(_:action:)` has both a LocalizedStringKey and a
                // StringProtocol overload, and handing it a ternary is a
                // needless overload-resolution puzzle in a file that has run
                // the type-checker out of budget before.
                Button {
                    batchSelection = batchSelection.count == photos.count
                        ? Set<String>() : Set(photos.map(\.id))
                    Haptics.selection()
                } label: {
                    Text(batchSelection.count == photos.count ? "Clear" : "Select all")
                        .font(.rpCaption.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
            Button { cancelBatchSelection() } label: {
                Text("Cancel")
                    .font(.rpCaption.weight(.semibold))
                    .foregroundStyle(Theme.inkDim)
            }
            Spacer(minLength: 4)
            Button { applyBatchSelection(pending) } label: {
                Text(pending.edit == "declutter"
                     ? "Review \(batchSelection.count) photos"
                     : batchSelection.isEmpty ? "Apply"
                     : "Apply to \(batchSelection.count) photo\(batchSelection.count == 1 ? "" : "s")")
                    .font(.rpCaption.weight(.bold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Theme.accent, in: Capsule())
            }
            .buttonStyle(ScalePressStyle())
            .disabled(batchSelection.isEmpty || isProcessing)
            .opacity(batchSelection.isEmpty || isProcessing ? 0.5 : 1)
            .accessibilityIdentifier("studio.batchApply")
        }
    }

    /// A running batch, with counts. A batch is minutes of work and money per
    /// photo, so it says which photo it is on and how many have failed WHILE it
    /// runs, not only at the end.
    private func batchProgressCard(_ run: BatchRun) -> some View {
        let stopping = photoJobs.visibleJob?.stopRequested == true
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView()
                Text(stopping ? "Stopping remaining edits" : "\(run.phase.title) — photo \(min(run.current, run.total)) of \(run.total)")
                    .font(.rpBody.weight(.semibold)).foregroundStyle(Theme.ink)
                    .lineLimit(2).minimumScaleFactor(0.8)
            }
            Text(run.phase.detail).font(.rpCaption).foregroundStyle(Theme.inkDim)
                .fixedSize(horizontal: false, vertical: true)
            // This bar counts completed attempts, not invented supplier progress.
            ProgressView(value: Double(run.done + run.failed), total: Double(max(run.total, 1)))
                .tint(Theme.accent)
                .accessibilityLabel("Batch completed attempts")
                .accessibilityValue("\(run.done) saved, \(run.failed) failed, \(run.total) total")
            Text(stopping ? "No more photos will be sent. The current request may finish and be charged; its saved result is kept." : run.failed == 0
                 ? "\(run.done) of \(run.total) saved. Earlier versions stay in history."
                 : "\(run.done) done, \(run.failed) failed. The rest keep going.")
                .font(.rpCaption)
                .foregroundStyle(run.failed == 0 ? Theme.inkDim : Theme.warn)
                .fixedSize(horizontal: false, vertical: true)
            Button { photoJobs.stopRemaining() } label: {
                Label(stopping ? "Remaining edits stopped" : "Stop remaining edits", systemImage: "stop.circle")
                    .font(.rpBody.weight(.semibold)).frame(minHeight: 44)
            }.disabled(stopping)
                .accessibilityIdentifier("photos.stopRemaining")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    /// What the last batch actually did. Stays until the agent starts something
    /// else — a run where 14 of 17 landed has to say so plainly, and must not
    /// wear a green tick while it says it.
    private func batchNoteCard(_ note: BatchNote) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: note.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(note.ok ? Theme.good : Theme.warn)
            Text(note.text)
                .font(.rpCaption).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button { batchNote = nil } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.inkDim)
            }
            .accessibilityLabel(Text("Dismiss"))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.fillSubtle, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// The line above the grid. It has to explain the grid's TWO modes now.
    private var studioGridHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(batchEdit == nil
                 ? "Tap a photo to see before and after. Tap the wand on a photo to change just that one."
                 : "Tap the photos you want changed — they get a tick.")
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
                .fixedSize(horizontal: false, vertical: true)
            // W2-C4: the agent learns this BEFORE they tap, not after
            // a broker asks. Disclosure is automatic, not optional.
            Label("Review saved disclosures and retained source photos before publishing. Export includes disclosure captions for your chosen destination.",
                  systemImage: "info.circle")
                .font(.rpCaption.weight(.semibold))
                .foregroundStyle(Theme.good)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// An edit-bar chip was tapped. Two roads out of here, and neither of them
    /// is a new way to spend money:
    ///
    ///  * NO PHOTOS YET → open the picker, remember the edit (and the staging
    ///    style, if it was a style button), and run it on the photo that lands.
    ///  * PHOTOS ON SCREEN → put the grid into selection mode and let the agent
    ///    say which ones. With 17 photos on a listing, "tap the wand, pick
    ///    Declutter" seventeen times is the workflow this exists to kill.
    ///
    /// Selecting a change and its photos is local work and stays available
    /// offline. The actual edit runners await the shared anonymous session
    /// without losing the selected photos or prompt. Consent and quota checks
    /// remain unchanged.
    private func startEdit(_ edit: String, style: String?, title: String,
                           multiple: Bool = true) {
        guard !isProcessing else { return }
        batchNote = nil
        guard !photos.isEmpty else {
            startShowcaseEdit(edit, style: style)
            return
        }
        batchEdit = PendingBatchEdit(edit: edit, style: style, title: title, multiple: multiple)
        // Pre-tick the whole listing for the fan-out edits: with 17 photos the
        // answer is almost always "all of them", and un-ticking three is less
        // work than ticking fourteen. Never for the one-at-a-time edits.
        batchSelection = multiple && edit != "stage" ? Set(photos.map(\.id)) : Set<String>()
        Haptics.selection()
    }

    /// A chip was tapped with no photos on screen: open the picker and remember
    /// the edit, so the photo the agent chooses gets it immediately.
    private func startShowcaseEdit(_ edit: String, style: String? = nil) {
        pendingShowcaseEdit = edit
        pendingShowcaseStyle = style
        showLibrary = true
        Haptics.selection()
    }

    /// Run the edit a chip asked for, now that a photo exists. Called from
    /// `ingest` AFTER `isProcessing` is cleared, so `aiEdit`'s one-job-at-a-time
    /// guard (F-A-22) lets it through.
    private func runPendingShowcaseEdit() {
        guard let edit = pendingShowcaseEdit else { return }
        let style = pendingShowcaseStyle
        pendingShowcaseEdit = nil
        pendingShowcaseStyle = nil
        guard let target = photos.first else { return }
        switch edit {
        case "animate":
            animate(target)
        case "stage":
            // A style button already answered "which style?" — do not ask again.
            if let style {
                aiEdit(target, "stage", style: style)
                return
            }
            // Staging needs a style first. Presenting a dialog in the same event
            // that dismissed the photo picker silently drops it, so chain it off
            // the run loop exactly the way the wand menu already does.
            stagePhoto = target
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { showStageDialog = true }
        case "custom":
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { openCustomEdit(target) }
        default:
            aiEdit(target, edit)
        }
    }

    /// Tick / untick one photo while an edit is waiting for its targets. The
    /// one-at-a-time edits (animate) replace the selection instead of adding to
    /// it — a minute of polling and a separate charge per photo is not something
    /// to fan out by accident.
    private func toggleBatchSelection(_ p: EnhancedPhoto) {
        guard let pending = batchEdit else { return }
        if !pending.multiple {
            batchSelection = batchSelection.contains(p.id) ? Set<String>() : Set([p.id])
        } else if batchSelection.contains(p.id) {
            batchSelection.remove(p.id)
        } else {
            batchSelection.insert(p.id)
        }
        Haptics.selection()
    }

    private func cancelBatchSelection() {
        batchEdit = nil
        batchSelection = []
    }

    /// Apply: turn the ticked ids back into photos, in GRID ORDER (the set has
    /// no order of its own and the progress line has to match what the agent is
    /// looking at), then hand them to the right runner.
    private func applyBatchSelection(_ pending: PendingBatchEdit) {
        let targets = photos.filter { batchSelection.contains($0.id) }
        guard !targets.isEmpty else { return }
        cancelBatchSelection()
        switch pending.edit {
        case "stage":
            connection.run { openStagingSetup(pending, targets: targets) }
        case "animate":
            // Never batched. `animate` is its own endpoint, its own poll and its
            // own charge; the chip is `multiple: false` so this is one photo.
            if let first = targets.first { animate(first) }
        case "custom":
            // The prompt comes first, from the sheet, and then goes to every
            // photo the agent ticked. The sheet previews the first of them.
            //
            // The retained action owns its targets while reconnecting. They
            // become view state only when the prompt can actually open.
            guard let first = targets.first else { return }
            openCustomEdit(first, batchTargets: targets)
        default:
            runBatch(pending, targets: targets)
        }
    }

    private func openStagingSetup(_ pending: PendingBatchEdit, targets: [EnhancedPhoto]) {
        guard !isProcessing, !targets.isEmpty else { return }
        let directory = EnhancedPhoto.directory(for: listing.id)
        guard let index = try? PhotoVersionHistory.load(directory: directory) else {
            aiFailure = AIFailure(PhotoVersionHistory.Failure.invalidHistory); return
        }
        let references = index.versions.values.filter {
            $0.effects.contains("stage") && $0.stagingReviewed == true && !index.hiddenFamilies.contains($0.familyID)
        }.sorted { $0.createdAt > $1.createdAt }.compactMap { version -> EnhancedPhoto? in
            guard (try? PhotoVersionHistory.stagingReference(id: version.id, directory: directory)) != nil else { return nil }
            return EnhancedPhoto(id: version.id, originalURL: directory.appendingPathComponent(version.reviewSourceFile(in: index)),
                                 enhancedURL: directory.appendingPathComponent(version.imageFile))
        }
        stagingSetup = PhotoStagingSetup(pending: pending, targets: targets, references: references)
    }

    /// Run ONE edit over MANY photos, in sequence, on the user's own account.
    ///
    /// There is no batch endpoint and no second billing path: this loops
    /// `performEdit`, which is the exact body `aiEdit` runs for a single photo —
    /// same `/ai-photo` call, same idempotency key per photo, same original
    /// published for disclosure per photo, same `ai_photo_edit` event per photo.
    /// Seventeen photos is seventeen edits, charged and metered as seventeen
    /// edits, because that is what it is.
    ///
    /// FAILURE IS REPORTED HONESTLY. One photo failing does not stop the other
    /// sixteen — except when the server says the allowance is gone (402) or the
    /// session expired (401), where continuing would burn fourteen more calls
    /// that cannot succeed. Those stop the run and surface the SAME alert a
    /// single edit shows, keeping its Upgrade plan / Retry connection buttons, with a
    /// line saying how many landed first.
    private func runBatch(_ pending: PendingBatchEdit, targets: [EnhancedPhoto],
                          prompt: String? = nil) {
        guard !isProcessing else { return }
        runPhotoAI { runBatchWithSession(pending, targets: targets, prompt: prompt) }
    }

    private func runBatchWithSession(_ pending: PendingBatchEdit, targets: [EnhancedPhoto],
                                     prompt: String?) {
        startPhotoWork(pending, targets: targets, prompt: prompt)
    }

    /// What the agent is told when a batch ends. Split out of `runBatch` so the
    /// task body stays readable and the wording lives in one place.
    private func finishBatch(_ pending: PendingBatchEdit, total: Int, done: Int,
                             failed: Int, firstFailure: AIFailure?, stoppedEarly: Bool) {
        let photoWord = done == 1 ? "photo" : "photos"
        if failed == 0 && !stoppedEarly {
            batchNote = BatchNote(
                text: "\(pending.title) — \(done) \(photoWord) changed. Earlier versions and source files stay in history.",
                ok: true)
            Haptics.success()
            return
        }
        Haptics.warning()
        let skipped = stoppedEarly ? total - done - failed : 0
        var lines = ["\(done) of \(total) photos changed. \(failed) failed."]
        if skipped > 0 { lines.append("\(skipped) were not attempted.") }
        if let firstFailure { lines.append("The first failure said: \(firstFailure.message)") }
        // Keep the failure's CLASS so a 402 still offers the in-app paywall and
        // a 401 still offers Retry connection — the message changes, the buttons do not.
        if let firstFailure {
            aiFailure = AIFailure(firstFailure,
                                  title: done > 0 ? "Some photos didn't change" : firstFailure.title,
                                  message: lines.joined(separator: "\n\n"))
        }
        if done > 0 {
            batchNote = BatchNote(text: "\(pending.title) — \(done) of \(total) photos changed, \(failed) failed.",
                                  ok: false)
        }
    }

    // MARK: - Files

    private func loadExisting() {
        photos = EnhancedPhoto.loadAll(listingID: listing.id)
        clips = SavedClip.loadAll(listingID: listing.id)
        refreshSavedAnimations()
        refreshSavedPhotoEdits()
        // Resolve each family's metadata independently. A missing selected
        // image still stops gallery upload, but doesn't erase other badges.
        do {
            let index = try PhotoVersionHistory.ensureOriginalSources(directory: dir)
            if entry == .studio {
                photos = index.libraryVersions(.original).map { version in
                    let image = dir.appendingPathComponent(version.imageFile)
                    return EnhancedPhoto(id: version.id, originalURL: image, enhancedURL: image)
                }
            }
            selectedPhotoIDs = Set(index.versions.keys.filter(index.isSelectedForListing))
            publicationLabels = Dictionary(uniqueKeysWithValues: index.versions.keys.map {
                ($0, index.publicationLabel(for: $0) ?? "Not selected for listing")
            })
        } catch {
            selectedPhotoIDs = []; publicationLabels = [:]
            photoSaveError = error.localizedDescription
        }
    }

    private var galleryReviewPhoto: EnhancedPhoto? {
        guard let mainRelPath else { return nil }
        let selected = (try? EnhancedPhoto.loadForListing(listingID: listing.id)) ?? []
        guard !selected.contains(where: { FileStore.relativePath(for: $0.enhancedURL) == mainRelPath }) else { return nil }
        return photos.flatMap(\.history).first { FileStore.relativePath(for: $0.enhancedURL) == mainRelPath }
    }

    @MainActor private func retryPublishedPhotos() {
        guard !galleryRetrying, let live = model.listings.first(where: { $0.id == listing.id }),
              live.cloudUnavailable != true, let serverID = live.serverID else { return }
        let context = NativeMediaExportContext()
        let targetID = live.id, main = live.mainPhotoRelPath, org = live.serverOrgID
        let selected: [String]
        do { selected = try EnhancedPhoto.loadForListing(listingID: targetID).map(\.id) }
        catch { photoSaveError = error.localizedDescription; return }
        galleryRetrying = true
        Task { @MainActor in
            defer { galleryRetrying = false }
            guard context.isCurrent,
                  let current = model.listings.first(where: { $0.id == targetID }), current.cloudUnavailable != true,
                  current.serverID == serverID, current.serverOrgID == org, current.mainPhotoRelPath == main,
                  (try? EnhancedPhoto.loadForListing(listingID: targetID).map(\.id)) == selected else { return }
            await model.syncGalleryPhotos(listingLocalID: targetID, listingServerID: serverID)
        }
    }

    /// Read the existing authenticated selection for every cloud listing.
    /// Opening Photos never sends a choice; an unpublished page needs the
    /// same confirmed state before its direct grid controls can show ticks.
    private func refreshListingPhotoSelection() {
        guard entry == .photos, !listing.isSample else { return }
        // An empty new phone must not clear cloud photos. An explicitly hidden
        // final family, however, is a real user removal with retained history.
        guard !photos.isEmpty || ((try? PhotoVersionHistory.load(directory: dir).versions.isEmpty) == false) else { return }
        let current = model.listings.first(where: { $0.id == listing.id })
        guard current?.cloudUnavailable != true, let serverID = current?.serverID else { return }
        let localID = listing.id
        Task { await model.syncGalleryPhotos(listingLocalID: localID, listingServerID: serverID) }
    }

    /// UI walk only (`-uiTesting -ui.seedPhotosDir`): the store screenshots need
    /// a studio with photos in it and a reel card that is live, and the system
    /// picker cannot be driven. Imports the seed files through the same
    /// `ingest` path a picked photo takes - once, into an empty real project.
    private func seedPhotosForUIWalk() {
        guard !listing.isSample, photos.isEmpty else { return }
        let urls = Config.uiTestSeedPhotoURLs
        guard !urls.isEmpty else { return }
        let images = urls.compactMap { url -> UIImage? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return UIImage(data: data)
        }
        ingest(images)
    }

    /// Library files are decoded and saved one at a time. Keep the exact
    /// representation delivered by Photos as the retained original; only the
    /// separate brightened copy is JPEG-encoded, without resizing or cropping.
    private func ingest(_ batch: PhotoImportBatch) {
        guard libraryImportID == batch.id else { batch.removeTemporaryFiles(); return }
        guard batch.context.matches(owner: AuthStore.shared.userID,
                                    revision: AuthStore.shared.syncSessionRevision,
                                    workspace: WorkspaceContext.selectedOrgID),
              !batch.cancellation.isCancelled else {
            batch.removeTemporaryFiles()
            localProcessing = false; libraryImportID = nil; libraryImportCancellation = nil
            pendingShowcaseEdit = nil; pendingShowcaseStyle = nil
            photoSaveError = "The account or workspace changed. No photos were imported into another account. Choose the photos again in the original listing."
            return
        }
        let targetDir = dir
        let existingIDs = Array(((try? PhotoVersionHistory.load(directory: targetDir).versions) ?? [:]).keys)
        processingText = "Saving your photos…"
        PhotoImportWriter.save(batch, existingIDs: existingIDs, process: { item, id in
            let original = try Data(contentsOf: item.url, options: .mappedIfSafe)
            guard let image = UIImage(data: original) else {
                throw NSError(domain: "RendpropPhotoImport", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "This image couldn't be decoded. Export it from Photos and try again."])
            }
            let enhanced = PhotoEnhancer.enhance(image)
            guard let jpeg = enhanced.jpegData(compressionQuality: 0.97) else {
                throw NSError(domain: "RendpropPhotoImport", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "Couldn't prepare the brightened copy. Free some space and try again."])
            }
            try PhotoVersionHistory.saveCapture(original: original, enhanced: jpeg, id: id, directory: targetDir, importOrderID: id, deduplicateOriginal: true)
        }, progress: { completed in
            DispatchQueue.main.async {
                guard libraryImportID == batch.id else { return }
                processingText = "Saving photo \(completed) of \(batch.requestedCount)…"
            }
        }, completion: { report in
            DispatchQueue.main.async {
                guard libraryImportID == batch.id else { return }
                localProcessing = false; libraryImportID = nil; libraryImportCancellation = nil
                guard batch.context.matches(owner: AuthStore.shared.userID,
                                            revision: AuthStore.shared.syncSessionRevision,
                                            workspace: WorkspaceContext.selectedOrgID) else {
                    pendingShowcaseEdit = nil; pendingShowcaseStyle = nil
                    // Any completed bytes remain in the original listing's
                    // directory. Never publish from a late account callback.
                    return
                }
                loadExisting()
                // Importing never chooses a cloud version or cover.
                if isCloudPhotoListing { refreshListingPhotoSelection() }
                else if mainRelPath == nil, let first = photos.first { setMain(first) }
                if let message = report.message {
                    photoSaveError = message
                    pendingShowcaseEdit = nil; pendingShowcaseStyle = nil
                } else { runPendingShowcaseEdit() }
            }
        })
    }

    private func ingest(_ images: [UIImage], completion: ((String?) -> Void)? = nil) {
        // An empty callback means the picker was cancelled (PHPicker still calls
        // back with no results). Drop any chip's pending edit rather than firing
        // it at the next photo the agent adds for some other reason.
        guard !images.isEmpty else {
            pendingShowcaseEdit = nil
            pendingShowcaseStyle = nil
            completion?(nil)
            return
        }
        guard !isProcessing else {
            completion?("Another photo is still saving. Please wait, then try again.")
            return
        }
        localProcessing = true
        photoSaveError = nil
        processingText = "Working on your photo…"
        let targetDir = dir
        let owner = AuthStore.shared.userID
        let revision = AuthStore.shared.syncSessionRevision
        let workspace = WorkspaceContext.selectedOrgID
        DispatchQueue.global(qos: .userInitiated).async {
            var failed = 0
            for img in images {
                // One pool PER PHOTO: the CIContext render and the two JPEG
                // encodes each leave large autoreleased buffers behind, and
                // holding fifteen of them until the loop ended was the studio's
                // worst memory spike (F-A-19).
                autoreleasepool {
                    let id = String(format: "%015d", Int(Date().timeIntervalSince1970 * 1000))
                        + "-" + UUID().uuidString
                    let enhanced = PhotoEnhancer.enhance(img)
                    guard let od = img.jpegData(compressionQuality: 0.95),
                          let ed = enhanced.jpegData(compressionQuality: 0.95) else {
                        failed += 1
                        return
                    }
                    do {
                        try PhotoVersionHistory.saveCapture(original: od, enhanced: ed, id: id, directory: targetDir, deduplicateOriginal: true)
                    } catch {
                        failed += 1
                    }
                }
            }
            let failureCount = failed
            DispatchQueue.main.async {
                localProcessing = false
                guard AuthStore.shared.userID == owner,
                      AuthStore.shared.syncSessionRevision == revision,
                      WorkspaceContext.selectedOrgID == workspace else {
                    // Durable bytes remain with the original local listing.
                    // A late callback must not publish them in another account.
                    completion?("Your account or workspace changed. Reopen this home's Photos to find any saved photos.")
                    return
                }
                loadExisting()
                // Local first photos become the card's cover automatically.
                if isCloudPhotoListing { refreshListingPhotoSelection() }
                else if mainRelPath == nil, let first = photos.first { setMain(first) }
                if failureCount > 0 {
                    let message = images.count == 1
                        ? "Couldn't save this photo. Free some space and try again."
                        : "\(failureCount) of \(images.count) photos couldn't be saved. Free some space and add those photos again."
                    photoSaveError = message
                    pendingShowcaseEdit = nil
                    pendingShowcaseStyle = nil
                    completion?(message)
                    return
                }
                // An empty-state chip may have been waiting on this photo.
                runPendingShowcaseEdit()
                completion?(nil)
            }
        }
    }

    /// Delete one stored motion clip. Nothing else points at the file, so this
    /// is unconditional — the confirmation happens at the call site.
    private func deleteClip(_ clip: SavedClip) {
        try? FileManager.default.removeItem(at: clip.url)
        loadExisting()
    }

    /// Non-destructive gallery removal: old reels, history and disclosures may
    /// still reference these files, so no photo bytes are deleted here.
    private func confirmDelete(_ p: EnhancedPhoto) {
        pendingPhotoDelete = p
        showPhotoDeleteConfirm = true
    }

    private func delete(_ p: EnhancedPhoto) {
        if isCloudPhotoListing {
            guard !galleryRetrying else { return }
            Task { await deleteCloudPhoto(p) }
            return
        }
        do {
            try PhotoVersionHistory.trackExisting(id: p.id, imageFile: p.enhancedURL.lastPathComponent,
                priorFile: p.originalURL == p.enhancedURL ? nil : p.originalURL.lastPathComponent, directory: dir)
            let coverFile = mainRelPath.map { FileStore.url(fromRelativePath: $0).lastPathComponent }
            let familyWasMain = try PhotoVersionHistory.familyContains(id: p.id, imageFile: coverFile, directory: dir)
            try PhotoVersionHistory.hide(id: p.id, directory: dir)
            loadExisting()
            if familyWasMain {
                let replacement = try PhotoVersionHistory.availableCoverVersion(directory: dir)
                model.setMainPhoto(replacement.map { FileStore.relativePath(for: dir.appendingPathComponent($0.imageFile)) }, for: listing.id)
            } else {
                refreshListingPhotoSelection()
            }
        } catch { photoSaveError = error.localizedDescription }
    }
    @MainActor private func deleteCloudPhoto(_ p: EnhancedPhoto) async {
        guard !galleryRetrying, let server = model.listings.first(where: { $0.id == listing.id })?.serverID else { return }
        let context = NativeMediaExportContext()
        galleryRetrying = true
        defer { galleryRetrying = false }
        do {
            _ = try await model.prepareCloudPhotoHide(listingID: listing.id, versionID: p.id)
            guard context.isCurrent, model.listings.first(where: { $0.id == listing.id })?.serverID == server else {
                throw PhotoCloudSelectionFailure.identityChanged
            }
            try PhotoVersionHistory.hide(id: p.id, directory: dir)
            loadExisting()
        } catch { if context.isCurrent { photoSaveError = error.localizedDescription } }
    }

}

/// Deterministic "pro real-estate" look — brighten shadows, recover highlights,
/// add vibrance/contrast, and sharpen. No network, no cost, runs on-device.
enum PhotoEnhancer {
    private static let context = CIContext()

    static func enhance(_ image: UIImage) -> UIImage {
        guard let cg = image.cgImage else { return image }
        var ci = CIImage(cgImage: cg).oriented(cgOrientation(image.imageOrientation))

        let hs = CIFilter.highlightShadowAdjust()
        hs.inputImage = ci; hs.shadowAmount = 0.5; hs.highlightAmount = 0.9; hs.radius = 10
        ci = hs.outputImage ?? ci

        let cc = CIFilter.colorControls()
        cc.inputImage = ci; cc.contrast = 1.06; cc.brightness = 0.02; cc.saturation = 1.06
        ci = cc.outputImage ?? ci

        let vb = CIFilter.vibrance()
        vb.inputImage = ci; vb.amount = 0.3
        ci = vb.outputImage ?? ci

        let sh = CIFilter.sharpenLuminance()
        sh.inputImage = ci; sh.sharpness = 0.5
        ci = sh.outputImage ?? ci

        guard let out = context.createCGImage(ci, from: ci.extent) else { return image }
        return UIImage(cgImage: out)
    }

    private static func cgOrientation(_ o: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch o {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
}

/// Intrinsic-width glass tabs keep every saved-version name readable. Compact
/// screens and larger text scroll instead of shrinking labels or clipping them.
private struct PhotoSavedVersionTabs: View {
    @Binding var selection: PhotoVersionHistory.LibraryKind
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(PhotoVersionHistory.LibraryKind.allCases) { kind in
                        Button { selection = kind } label: {
                            Text(kind.rawValue)
                                .font(.subheadline.weight(.semibold))
                                .fixedSize(horizontal: true, vertical: false)
                                .foregroundStyle(selection == kind ? Theme.accent : Theme.ink)
                                .padding(.horizontal, 12).padding(.vertical, 10)
                                .frame(minHeight: 44)
                                .background(selection == kind ? Theme.accentSoft : Color.clear, in: Capsule())
                                .background(.thinMaterial, in: Capsule())
                                .overlay(Capsule().strokeBorder(selection == kind ? Theme.accent.opacity(0.3) : Theme.border))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(kind.rawValue)
                        .accessibilityAddTraits(selection == kind ? .isSelected : [])
                        .accessibilityIdentifier("photos.savedVersion.\(kind.rawValue.lowercased())")
                        .id(kind.id)
                    }
                }
                .padding(2)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Saved photo versions")
            .accessibilityIdentifier("photos.savedVersions")
            .onChange(of: selection) { kind in
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    proxy.scrollTo(kind.id, anchor: .center)
                }
            }
        }
    }
}

/// Keep the thumbnail's generic metadata shallow. This named boundary also
/// keeps publication and cover labels independent of save-to-Photos controls.
private struct PhotoPublicationBadges: View {
    let isCover: Bool
    let publicationLabel: String?
    let photoID: String
    let selectedForListing: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isCover {
                PhotoPublicationBadge(title: "Cover", icon: "star.fill", color: Theme.accent)
            }
            if let publicationLabel {
                PhotoPublicationBadge(title: publicationLabel,
                    icon: selectedForListing || publicationLabel == "Another version on listing" ? "checkmark.circle.fill" : "circle",
                    color: selectedForListing || publicationLabel == "Another version on listing" ? Theme.good : Theme.inkDim)
                    .accessibilityIdentifier(selectedForListing ? "photos.listingSelected.\(photoID)" : "photos.listingVersion.\(photoID)")
            }
        }.padding(8).allowsHitTesting(false)
    }
}

private struct PhotoPublicationBadge: View {
    let title: String
    let icon: String
    let color: Color
    var body: some View {
        Label(title, systemImage: icon)
            .font(.caption2.weight(.semibold))
            .lineLimit(1).minimumScaleFactor(0.75)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(color, in: Capsule()).foregroundStyle(Color.white)
    }
}

/// Full-screen before/after compare. Both images decode once, off the main
/// thread, at screen resolution.
/// Keeps the photo large and footer readable across compact phones and larger text.
/// No source/export geometry is changed by this display-only calculation.
private enum PhotoReviewLayout {
    static func previewHeight(imageSize: CGSize?, availableWidth: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        let heightLimit = viewportHeight.isFinite ? max(0, min(420, viewportHeight * 0.50)) : 420
        guard let imageSize, imageSize.width.isFinite, imageSize.height.isFinite,
              imageSize.width > 0, imageSize.height > 0,
              availableWidth.isFinite, availableWidth > 0 else {
            return min(200, heightLimit)
        }
        // Decoding already applies source orientation. Use the displayed image's
        // proportions rather than reserving an empty portrait-shaped container.
        return min(heightLimit, availableWidth * (imageSize.height / imageSize.width))
    }
    static func previewWidth(imageSize: CGSize?, availableWidth: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        guard let imageSize, imageSize.width.isFinite, imageSize.height.isFinite,
              imageSize.width > 0, imageSize.height > 0,
              availableWidth.isFinite, availableWidth > 0 else {
            return availableWidth.isFinite ? max(0, availableWidth) : 0
        }
        let height = previewHeight(imageSize: imageSize, availableWidth: availableWidth, viewportHeight: viewportHeight)
        return min(availableWidth, height * (imageSize.width / imageSize.height))
    }
    static func stacksActions(width: CGFloat, accessibilityType: Bool) -> Bool {
        accessibilityType || width < 320
    }
}

/// Closed choices share the existing photo service; none enters bulk selection.
private enum PhotoReviewEdit: Equatable {
    case declutter, stage(String), twilight, sky, lawn, custom
    var edit: String {
        switch self {
        case .declutter: return "declutter"
        case .stage: return "stage"
        case .twilight: return "twilight"
        case .sky: return "sky"
        case .lawn: return "lawn"
        case .custom: return "custom"
        }
    }
    var style: String? { if case .stage(let style) = self { return style }; return nil }
    var title: String {
        switch self {
        case .declutter: return "Declutter"
        case .stage: return "Staging"
        case .twilight: return "Twilight"
        case .sky: return "Blue sky"
        case .lawn: return "Green lawn"
        case .custom: return "Custom edit"
        }
    }
}

private struct PhotoReviewEditSheet: View {
    let original: EnhancedPhoto
    let space: SpaceType
    let choose: (PhotoReviewEdit) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var pickingStyle = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    DetailPhotoThumb(url: original.enhancedURL, height: 180)
                    Text("Change just this photo").font(.title2.bold()).foregroundStyle(Theme.ink)
                    Text("Each action starts from this photo’s Original. Your saved edits stay in history. Review the new version before using it on your listing.")
                        .font(.subheadline).foregroundStyle(Theme.inkDim)
                        .fixedSize(horizontal: false, vertical: true)
                    if pickingStyle {
                        Text(space == .realEstate ? "Choose a staging style" : "Choose a furnishing style")
                            .font(.headline).foregroundStyle(Theme.ink)
                        ForEach(StagingStyle.all) { style in
                            SecondaryButton(title: style.label, systemImage: "sofa") { select(.stage(style.id)) }
                                .accessibilityIdentifier("photoVersion.edit.stage.\(style.id)")
                        }
                        SecondaryButton(title: "Back to photo actions", systemImage: "arrow.left") { pickingStyle = false }
                    } else {
                        PrimaryButton(title: "Declutter this photo", systemImage: "sparkles") { select(.declutter) }
                            .accessibilityIdentifier("photoVersion.edit.declutter")
                        SecondaryButton(title: space == .realEstate ? "Stage this photo" : "Furnish this photo", systemImage: "sofa") { pickingStyle = true }
                            .accessibilityIdentifier("photoVersion.edit.stage")
                        SecondaryButton(title: "Make it twilight", systemImage: "sun.horizon") { select(.twilight) }
                        SecondaryButton(title: "Make the sky blue", systemImage: "cloud.sun") { select(.sky) }
                        if space == .realEstate {
                            SecondaryButton(title: "Make the lawn green", systemImage: "leaf") { select(.lawn) }
                        }
                        SecondaryButton(title: "Ask for a custom edit", systemImage: "text.bubble") { select(.custom) }
                            .accessibilityIdentifier("photoVersion.edit.custom")
                    }
                    Text("One photo edit counts against your plan. No other photos are selected or changed.")
                        .font(.caption).foregroundStyle(Theme.inkDim).fixedSize(horizontal: false, vertical: true)
                }.padding(16).frame(maxWidth: 760).frame(maxWidth: .infinity)
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Edit original photo").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
    private func select(_ action: PhotoReviewEdit) { choose(action); dismiss() }
}

private struct PhotoReviewFooterHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct PhotoCompareView: View {
    let photo: EnhancedPhoto
    var disclosure: String? = nil
    var requestedCover = false
    var galleryPhotos: [EnhancedPhoto] = []
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var auth = AuthStore.shared
    @State private var selectedVersion: EnhancedPhoto?
    @State private var rememberedFamilyVersions: [String: EnhancedPhoto] = [:]
    @State private var showOriginal = false
    @State private var enhanced: UIImage?
    @State private var original: UIImage?
    @State private var exporting: PhotoExportSelection?
    @State private var showFullComparison = false
    @State private var showVersionHistory = false
    @State private var showAccessibilityFeedback = false
    @State private var feedbackReasonReveal: FeedbackReasonReveal?
    @State private var imageContext: NativeMediaExportContext?
    @State private var selectionError: String?
    @State private var selectedForListing = false
    @State private var confirmCloudCoverFollow = false
    @State private var selectionWorkID: UUID?
    @State private var imageLoadComplete = false
    @State private var stagingReview = PhotoVersionHistory.StagingReview()
    @State private var customReview = PhotoVersionHistory.CustomReview()
    @ObservedObject private var photoJobs = PhotoWorkQueue.shared
    @StateObject private var editConnection = FeatureSessionAction()
    @State private var editOriginal: EnhancedPhoto?
    @State private var singleDeclutterReview: PhotoDeclutterReviewModel?
    @State private var editContext: NativeMediaExportContext?
    @State private var editConsentRevision: UInt64?
    @State private var showEditActions = false
    @State private var pendingEdit: PhotoReviewEdit?
    @State private var singleStagingSetup: PhotoStagingSetup?
    @State private var singleCustomPhoto: EnhancedPhoto?
    @State private var singleEditJobID: UUID?
    @State private var actionFooterHeight: CGFloat = 0

    private struct FeedbackReasonReveal: Equatable {
        let versionID: String
        let token = UUID()
    }

    private var viewed: EnhancedPhoto { selectedVersion ?? photo }
    private var photoListingID: UUID? { UUID(uuidString: viewed.enhancedURL.deletingLastPathComponent().lastPathComponent) }
    private var isCloudListing: Bool { photoListingID.flatMap { id in model.listings.first(where: { $0.id == id })?.serverID } != nil }
    private var cloudProjection: PhotoCloudSelectionProjection? { photoListingID.flatMap { model.cloudPhotoProjection(for: $0) } }
    private var publicationSelected: Bool { isCloudListing ? cloudProjection?.selectedVersionIDs.contains(viewed.id) == true : selectedForListing }
    private var cloudCoverRequested: Bool { isCloudListing && requestedCoverForViewed }
    private var cloudSelectionKnown: Bool {
        guard isCloudListing, let family = viewed.savedVersion?.familyID, let cloudProjection else { return false }
        return cloudProjection.mutableFamilyIDs.contains(family) && !cloudProjection.pending
    }
    private var needsStagingReview: Bool {
        viewed.savedVersion?.effects.contains("stage") == true && viewed.savedVersion?.stagingReviewed != true
    }
    private var needsCustomReview: Bool { viewed.savedVersion?.needsCustomReview == true }
    private var sourceTitle: String { viewed.retainedSourceIsVerified ? "Retained original" : "Earlier source" }
    private var savedDisclosure: String? { viewed.savedVersion?.reviewDisclosure ?? (viewed.id == photo.id ? disclosure : nil) }
    private var versionChoices: [EnhancedPhoto] {
        let history = viewed.history
        var kinds: Set<String> = []
        let choices = history.filter { version in
            let effects = version.savedVersion?.effects ?? []
            let source = version.savedVersion.map { $0.parentID == nil && $0.imageFile == $0.originalFile } ?? false
            let kind = source ? "Original" : effects.contains("stage") ? "Staged" : effects.contains("declutter") ? "Decluttered" : "Enhanced"
            return kinds.insert(kind).inserted
        }
        // Keep the retained source first without changing which saved edit
        // represents each category or the order of the remaining categories.
        return choices.filter { $0.savedVersion.map { $0.parentID == nil && $0.imageFile == $0.originalFile } == true }
            + choices.filter { $0.savedVersion.map { $0.parentID == nil && $0.imageFile == $0.originalFile } != true }
    }
    private func choiceTitle(_ version: EnhancedPhoto) -> String {
        if let saved = version.savedVersion, saved.parentID == nil && saved.imageFile == saved.originalFile {
            return saved.originalVerified ? "Original" : "Earlier source"
        }
        let effects = version.savedVersion?.effects ?? []
        return effects.contains("stage") ? "Staged" : effects.contains("declutter") ? "Decluttered" : "Enhanced"
    }

    private func isRetainedSource(_ version: EnhancedPhoto) -> Bool {
        guard let saved = version.savedVersion,
              saved.parentID == nil, saved.imageFile == saved.originalFile else { return false }
        return version.enhancedURL.standardizedFileURL == viewed.originalURL.standardizedFileURL
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollViewReader { scroll in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            familyNavigation
                            savedVersionStrip(stacked: geometry.size.width < 320 || dynamicTypeSize >= .xxLarge)
                            reviewTools(stacked: geometry.size.width < 320 || dynamicTypeSize >= .xxLarge)
                            ZStack {
                                if let image = showOriginal ? original : enhanced {
                                    Image(uiImage: image).resizable().scaledToFit()
                                        .accessibilityLabel(showOriginal ? sourceTitle : choiceTitle(viewed) + " photo")
                                } else if imageLoadComplete {
                                    Label("Photo unavailable", systemImage: "photo.badge.exclamationmark")
                                        .foregroundStyle(Theme.inkDim)
                                } else { ProgressView().tint(Theme.accent) }
                            }
                            .frame(width: PhotoReviewLayout.previewWidth(
                                imageSize: (showOriginal ? original : enhanced)?.size,
                                availableWidth: max(0, min(760, geometry.size.width) - 32),
                                viewportHeight: geometry.size.height))
                            .frame(height: PhotoReviewLayout.previewHeight(
                                imageSize: (showOriginal ? original : enhanced)?.size,
                                availableWidth: max(0, min(760, geometry.size.width) - 32),
                                viewportHeight: geometry.size.height))
                            .background(Theme.fillSubtle, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                            .frame(maxWidth: .infinity, alignment: .center)
                            .accessibilityIdentifier("photoVersion.preview")
                            .simultaneousGesture(DragGesture(minimumDistance: 30).onEnded { value in
                                if let offset = PhotoFamilyPager.swipeOffset(horizontal: Double(value.translation.width), vertical: Double(value.translation.height)) {
                                    movePhotoFamily(offset)
                                }
                            })
                            .accessibilityAction(named: Text("Previous photo")) { movePhotoFamily(-1) }
                            .accessibilityAction(named: Text("Next photo")) { movePhotoFamily(1) }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(showOriginal ? sourceTitle : viewed.savedVersion?.visibleLabel ?? choiceTitle(viewed))
                                    .font(.headline).foregroundStyle(Theme.ink)
                                if publicationSelected, !showOriginal {
                                    Label("Selected for listing", systemImage: "checkmark.circle.fill")
                                        .font(.caption).foregroundStyle(Theme.good)
                                }
                            }
                            reviewDetails
                            if isCloudListing, cloudProjection?.pending == true {
                                SecondaryButton(title: "Discard saved photo choice", systemImage: "xmark.circle", isDisabled: selectionWorkID != nil, isCompact: true) {
                                    abandonSavedCloudSelection()
                                }
                                Text("Only a request that never started can be discarded. A completed choice is kept and refreshed.")
                                    .font(.caption).foregroundStyle(Theme.inkDim)
                            }
                        }
                        // At accessibility text sizes the two fixed actions can
                        // occupy much of the viewport. Keep the final review
                        // control scrollable above their measured height.
                        .padding(.bottom, dynamicTypeSize.isAccessibilitySize ? actionFooterHeight : 0)
                        .padding(16)
                        .frame(maxWidth: 760)
                        .frame(maxWidth: .infinity)
                    }
                    .accessibilityIdentifier("photoVersion.scroll")
                    .background(Theme.bg.ignoresSafeArea())
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        actionFooter(stacked: PhotoReviewLayout.stacksActions(width: geometry.size.width,
                            accessibilityType: dynamicTypeSize.isAccessibilitySize))
                    }
                    .onPreferenceChange(PhotoReviewFooterHeightPreferenceKey.self) { actionFooterHeight = $0 }
                    .onChange(of: feedbackReasonReveal) { request in
                        guard let request, !showOriginal, viewed.savedVersion?.id == request.versionID else { return }
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                            scroll.scrollTo(PhotoFeedbackControl.reasonPromptID(for: request.versionID), anchor: .top)
                        }
                    }
                }
            }
            .navigationTitle("Photo versions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { reviewNavigation }
        }
        .onChange(of: auth.userID) { _ in clearAndDismiss() }
        .onChange(of: auth.syncSessionRevision) { _ in clearAndDismiss() }
        .onReceive(NotificationCenter.default.publisher(for: .rendpropWorkspaceChanged)) { _ in clearAndDismiss() }
        .onReceive(photoJobs.$job) { receiveSinglePhotoWork($0) }
        .sheet(isPresented: $showVersionHistory) { reviewHistorySheet }
        .sheet(isPresented: $showAccessibilityFeedback) { accessibilityFeedbackSheet }
        .sheet(isPresented: $showEditActions, onDismiss: continueSinglePhotoEdit) {
            if let editOriginal, let listing = reviewListing {
                PhotoReviewEditSheet(original: editOriginal, space: listing.isSample ? SpaceType.current : listing.spaceType) {
                    pendingEdit = $0
                }
            }
        }
        .sheet(item: $singleStagingSetup, onDismiss: finishSinglePhotoSetup) { setup in
            PhotoStagingSetupView(setup: setup) { referenceID, brief in
                singleStagingSetup = nil
                guard setup.isCurrent else { return }
                startSinglePhotoWork(.stage(setup.pending.style ?? "modern"), prompt: brief,
                                     stagingReferenceID: referenceID)
            }
        }
        .sheet(item: $singleDeclutterReview, onDismiss: finishSinglePhotoSetup) { review in
            PhotoDeclutterReviewSheet(review: review) { photos, approvals in
                singleDeclutterReview = nil
                guard review.isCurrent, !photos.isEmpty else { clearSinglePhotoEdit(); return }
                startSinglePhotoWork(.declutter, prompt: nil, declutterApprovals: approvals)
            }
        }
        .sheet(item: $singleCustomPhoto, onDismiss: finishSinglePhotoSetup) { source in
            if let listing = reviewListing {
                CustomEditSheet(photo: source, api: model.api,
                    space: listing.isSample ? SpaceType.current : listing.spaceType,
                    listingServerID: listing.serverID) { prompt in
                        singleCustomPhoto = nil
                        startSinglePhotoWork(.custom, prompt: prompt)
                    }
            }
        }
        .fullScreenCover(isPresented: $showFullComparison) {
            if let enhanced, imageContext?.isCurrent == true {
                PhotoFullSizeComparison(edited: enhanced, source: viewed.originalURL == viewed.enhancedURL ? nil : original, sourceTitle: sourceTitle,
                    showOriginal: $showOriginal)
            }
        }
        .sheet(item: $exporting) { selection in
            PhotoExportSheet(photos: selection.photos, original: selection.original, onExported: PhotoFeedbackQueue.recordExport)
        }
        .alert("Photo action needs attention", isPresented: Binding(get: { selectionError != nil }, set: { if !$0 { selectionError = nil } })) {
            Button("OK") { selectionError = nil }
        } message: { Text(selectionError ?? "") }
        .confirmationDialog("Use this version as the listing cover too?", isPresented: $confirmCloudCoverFollow, titleVisibility: .visible) {
            Button("Use version and keep it as cover") { beginCloudSelection(followCover: true) }
            Button("Cancel", role: .cancel) {}
        }
        .task(id: viewed.id) {
            let context = NativeMediaExportContext()
            imageContext = context
            let target = viewed
            let directory = target.enhancedURL.deletingLastPathComponent()
            selectedForListing = !isCloudListing && (try? PhotoVersionHistory.load(directory: directory).isSelectedForListing(viewed.id)) == true
            if isCloudListing, let listingID = photoListingID {
                do { _ = try await model.refreshCloudPhotoSelection(listingID: listingID) }
                catch is CancellationError { return }
                catch { if context.isCurrent, viewed.id == target.id { selectionError = error.localizedDescription } }
            }
            guard context.isCurrent, viewed.id == target.id, !Task.isCancelled else { return }
            stagingReview = PhotoVersionHistory.StagingReview()
            customReview = PhotoVersionHistory.CustomReview()
            enhanced = nil; original = nil; imageLoadComplete = false
            let after = await AIImagePrep.decoded(at: target.enhancedURL, maxPixel: 2400)
            guard context.isCurrent, viewed.id == target.id else { return }
            enhanced = after
            let before = target.originalURL == target.enhancedURL ? after
                : await AIImagePrep.decoded(at: target.originalURL, maxPixel: 2400)
            guard context.isCurrent, viewed.id == target.id else { return }
            original = before
            imageLoadComplete = true
            if showOriginal, before != nil, target.originalURL != target.enhancedURL {
                stagingReview.comparedSource = true
                customReview.comparedSource = true
            }
        }
        .onChange(of: showOriginal) { showing in
            if showing, imageContext?.isCurrent == true, original != nil, viewed.originalURL != viewed.enhancedURL {
                stagingReview.comparedSource = true
                customReview.comparedSource = true
            }
        }
        .sessionConnectionNotice(isActive: editConnection.isWaiting, onCancel: { clearSinglePhotoEdit() })
        .aiConsentGate()
    }

    private var familyPhotos: [EnhancedPhoto] {
        guard !galleryPhotos.isEmpty else { return [] }
        let directory = photo.enhancedURL.deletingLastPathComponent()
        guard let index = try? PhotoVersionHistory.load(directory: directory) else { return [] }
        return PhotoFamilyPager.photos([photo] + galleryPhotos, index: index, directory: directory)
    }

    private var familyPosition: Int? {
        let directory = photo.enhancedURL.deletingLastPathComponent()
        guard let index = try? PhotoVersionHistory.load(directory: directory),
              let family = PhotoFamilyPager.family(of: viewed, index: index, directory: directory) else { return nil }
        return familyPhotos.firstIndex { PhotoFamilyPager.family(of: $0, index: index, directory: directory) == family }
    }

    private var canNavigateFamilies: Bool {
        imageContext?.isCurrent == true && reviewListing != nil && selectionWorkID == nil
            && editContext == nil && singleEditJobID == nil && !showEditActions
            && pendingEdit == nil && singleStagingSetup == nil && singleCustomPhoto == nil
            && !editConnection.isWaiting && !showFullComparison && exporting == nil
    }

    private var requestedCoverForViewed: Bool {
        let directory = photo.enhancedURL.deletingLastPathComponent()
        guard requestedCover, let index = try? PhotoVersionHistory.load(directory: directory),
              let initial = PhotoFamilyPager.family(of: photo, index: index, directory: directory) else { return false }
        return PhotoFamilyPager.family(of: viewed, index: index, directory: directory) == initial
    }

    @ViewBuilder private var familyNavigation: some View {
        if let position = familyPosition, !familyPhotos.isEmpty {
            HStack(spacing: 12) {
                Button { Haptics.selection(); movePhotoFamily(-1) } label: {
                    Image(systemName: "chevron.left").font(.subheadline.weight(.semibold))
                        .frame(width: 32, height: 32)
                        .background(Theme.accentSoft, in: Circle())
                        .foregroundStyle(!canNavigateFamilies || position == 0 ? Theme.disabledInk : Theme.accent)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canNavigateFamilies || position == 0)
                .accessibilityLabel("Previous photo")
                .accessibilityIdentifier("photoVersion.previousPhoto")
                Spacer(minLength: 0)
                Text("\(position + 1) of \(familyPhotos.count)")
                    .font(.subheadline.monospacedDigit()).foregroundStyle(Theme.inkDim)
                    .accessibilityLabel("Photo \(position + 1) of \(familyPhotos.count)")
                    .accessibilityIdentifier("photoVersion.position")
                Spacer(minLength: 0)
                Button { Haptics.selection(); movePhotoFamily(1) } label: {
                    Image(systemName: "chevron.right").font(.subheadline.weight(.semibold))
                        .frame(width: 32, height: 32)
                        .background(Theme.accentSoft, in: Circle())
                        .foregroundStyle(!canNavigateFamilies || position + 1 >= familyPhotos.count ? Theme.disabledInk : Theme.accent)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canNavigateFamilies || position + 1 >= familyPhotos.count)
                .accessibilityLabel("Next photo")
                .accessibilityIdentifier("photoVersion.nextPhoto")
            }
        }
    }

    private func movePhotoFamily(_ offset: Int) {
        guard canNavigateFamilies else { return }
        let directory = photo.enhancedURL.deletingLastPathComponent()
        guard let index = try? PhotoVersionHistory.load(directory: directory),
              let current = PhotoFamilyPager.family(of: viewed, index: index, directory: directory),
              let target = PhotoFamilyPager.destination(from: viewed, offset: offset,
                  candidates: [photo] + galleryPhotos, remembered: rememberedFamilyVersions,
                  index: index, directory: directory) else { return }
        rememberedFamilyVersions[current] = viewed
        clearSinglePhotoEdit()
        selectionError = nil
        selectedForListing = false
        chooseVersion(target)
    }

    private var reviewListing: Listing? {
        guard let id = UUID(uuidString: photo.enhancedURL.deletingLastPathComponent().lastPathComponent) else { return nil }
        return model.listings.first { $0.id == id && $0.cloudUnavailable != true }
    }

    private var singlePhotoEditing: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let job = photoJobs.visibleJob, job.id == singleEditJobID, job.running {
                HStack(alignment: .top, spacing: 10) {
                    ProgressView().tint(Theme.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(job.phase?.title ?? "Preparing photo").font(.subheadline.weight(.semibold))
                        Text(job.phase?.detail ?? "Your saved versions stay unchanged.").font(.caption).foregroundStyle(Theme.inkDim)
                    }
                }
                .accessibilityIdentifier("photoVersion.edit.progress")
                SecondaryButton(title: "Stop photo edit", systemImage: "stop.circle", isCompact: true) { photoJobs.cancel() }
            } else {
                SecondaryButton(title: "Edit", systemImage: "wand.and.stars",
                    isDisabled: imageContext?.isCurrent != true || selectionWorkID != nil
                        || photoJobs.visibleJob?.running == true || editConnection.isWaiting || reviewListing == nil,
                    isCompact: true,
                    action: openSinglePhotoEdit)
                    .accessibilityIdentifier("photoVersion.editOriginal")
                    .accessibilityLabel("Edit original photo")
                    .accessibilityHint("Declutter, stage or edit only this photo’s retained Original. Saved versions stay unchanged.")
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func reviewTools(stacked: Bool) -> some View {
        Group {
            if stacked {
                VStack(spacing: 8) { singlePhotoEditing; comparisonButton }
            } else {
                HStack(alignment: .top, spacing: 10) { singlePhotoEditing; comparisonButton }
            }
        }
    }

    private var comparisonButton: some View {
        SecondaryButton(title: "Compare", systemImage: "square.split.2x1",
            isDisabled: enhanced == nil || imageContext?.isCurrent != true, isCompact: true) {
                guard imageContext?.isCurrent == true else { clearAndDismiss(); return }
                showFullComparison = true
            }
            .disabled(enhanced == nil || imageContext?.isCurrent != true)
            .accessibilityIdentifier("photoVersion.fullSize")
            .accessibilityHint("Inspect this version beside its retained source at full size.")
    }

    private func openSinglePhotoEdit() {
        guard imageContext?.isCurrent == true, reviewListing != nil,
              selectionWorkID == nil, photoJobs.visibleJob?.running != true else { return }
        do {
            let directory = viewed.enhancedURL.deletingLastPathComponent()
            let source = try PhotoVersionHistory.originalForEditing(id: viewed.id, directory: directory)
            let url = directory.appendingPathComponent(source.imageFile)
            editOriginal = EnhancedPhoto(id: source.id, originalURL: url, enhancedURL: url)
            editContext = NativeMediaExportContext()
            pendingEdit = nil
            showEditActions = true
        } catch { selectionError = error.localizedDescription }
    }

    private func continueSinglePhotoEdit() {
        guard let action = pendingEdit else { clearSinglePhotoEdit(); return }
        pendingEdit = nil
        guard let source = editOriginal, let context = editContext, context.isCurrent else { clearSinglePhotoEdit(); return }
        Task { @MainActor in
            guard await AIConsent.shared.ensureGranted(), context.isCurrent else { clearSinglePhotoEdit(); return }
            let consentRevision = AIConsent.shared.revocationRevision
            editConsentRevision = consentRevision
            editConnection.run { [self] in
                guard context.isCurrent, editContext?.isCurrent == true, AIConsent.shared.isGranted,
                      AIConsent.shared.revocationRevision == consentRevision,
                      reviewListing != nil, photoJobs.visibleJob?.running != true else { clearSinglePhotoEdit(); return }
                if case .stage = action {
                    singleStagingSetup = PhotoStagingSetup(
                        pending: PendingBatchEdit(edit: action.edit, style: action.style, title: action.title, multiple: false),
                        targets: [source], references: [])
                } else if action == .custom {
                    singleCustomPhoto = source
                } else {
                    startSinglePhotoWork(action, prompt: nil)
                }
            }
        }
    }

    private func startSinglePhotoWork(_ action: PhotoReviewEdit, prompt: String?, stagingReferenceID: String? = nil,
                                     declutterApprovals: [String: DeclutterGenerationApproval]? = nil) {
        guard let source = editOriginal, let context = editContext, context.isCurrent,
              imageContext?.isCurrent == true, AIConsent.shared.isGranted,
              editConsentRevision == AIConsent.shared.revocationRevision,
              let listing = reviewListing, photoJobs.visibleJob?.running != true else { return }
        if action == .declutter, declutterApprovals == nil {
            singleDeclutterReview = PhotoDeclutterReviewModel(model: model, listing: listing, photos: [source],
                space: listing.isSample ? SpaceType.current : listing.spaceType)
            return
        }
        let service = PhotoEditService(model: model, listing: listing,
            space: listing.isSample ? SpaceType.current : listing.spaceType)
        if service.start(title: action.title, photos: [source], edit: action.edit,
                         style: action.style, prompt: prompt, stagingReferenceID: stagingReferenceID,
                         declutterApprovals: declutterApprovals) {
            singleEditJobID = photoJobs.visibleJob?.id
            Haptics.selection()
        }
    }

    private func receiveSinglePhotoWork(_ job: PhotoWorkQueue.Job?) {
        guard let job, job.id == singleEditJobID, !job.running,
              editContext?.isCurrent == true, imageContext?.isCurrent == true,
              let source = editOriginal else { return }
        singleEditJobID = nil
        if let failure = job.failures.first {
            if AIFailure.requiresSavedPhotoCheck(failure.error) {
                selectionError = "The result is not confirmed. Open Photos and choose Check saved edit instead of starting another edit. Your request is retained."
            } else { selectionError = AIFailure(failure.error).fullMessage }
        } else if job.done == 1 {
            let directory = source.enhancedURL.deletingLastPathComponent()
            if let index = try? PhotoVersionHistory.load(directory: directory),
               let family = index.versions[source.id]?.familyID, let latestID = index.current[family],
               let latest = index.versions[latestID] {
                chooseVersion(EnhancedPhoto(id: latest.id,
                    originalURL: directory.appendingPathComponent(latest.reviewSourceFile(in: index)),
                    enhancedURL: directory.appendingPathComponent(latest.imageFile)))
            }
        }
        clearSinglePhotoEdit()
    }


    @ToolbarContentBuilder private var reviewNavigation: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button { clearAndDismiss() } label: {
                Image(systemName: "xmark").frame(width: 44, height: 44)
            }
            .accessibilityLabel("Close")
            .accessibilityIdentifier("photoVersion.close")
        }
        if dynamicTypeSize.isAccessibilitySize, !showOriginal,
           let feedbackVersion = viewed.savedVersion, PhotoFeedbackQueue.shared.canRecord(feedbackVersion) {
            ToolbarItem(placement: .primaryAction) {
                Button { showAccessibilityFeedback = true } label: {
                    Label("Photo feedback", systemImage: "bubble.left.and.bubble.right")
                        .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Photo feedback")
                .accessibilityHint("Optional feedback about this saved edit. It does not change your photo or listing.")
                .accessibilityIdentifier("photoVersion.feedback.open")
            }
        }
        if viewed.history.count > 1 {
            ToolbarItem(placement: .primaryAction) {
                Button { showVersionHistory = true } label: {
                    Label("All edits", systemImage: "clock.arrow.circlepath")
                        .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("All edits")
                .accessibilityHint("Every saved style and earlier version remains available.")
                .accessibilityIdentifier("photoVersion.history")
            }
        }
    }

    private var accessibilityFeedbackSheet: some View {
        NavigationStack {
            ScrollViewReader { scroll in
                ScrollView {
                    if !showOriginal, let feedbackVersion = viewed.savedVersion,
                       PhotoFeedbackQueue.shared.canRecord(feedbackVersion) {
                        PhotoFeedbackControl(version: feedbackVersion,
                                             directory: viewed.enhancedURL.deletingLastPathComponent(),
                                             cloudListing: isCloudListing, listingSelected: publicationSelected,
                                             exportOpened: exporting != nil,
                                             onRevealReasons: { versionID in
                                                 withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                                                     scroll.scrollTo(PhotoFeedbackControl.reasonPromptID(for: versionID), anchor: .top)
                                                 }
                                             }, presentsReasonSheet: false)
                            .id(feedbackVersion.id)
                            .padding(20)
                            .frame(maxWidth: 760)
                            .frame(maxWidth: .infinity)
                    }
                }
                .accessibilityIdentifier("photoVersion.feedback.reasonSheet.scroll")
                .background(Theme.bg.ignoresSafeArea())
            }
            .navigationTitle("Photo feedback")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { showAccessibilityFeedback = false }
                        .accessibilityIdentifier("photoVersion.feedback.close")
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var reviewHistorySheet: some View {
        NavigationStack {
            List(viewed.history) { version in historyVersionButton(version) }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(Theme.bg)
                .navigationTitle("All edits")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { showVersionHistory = false }
                    }
                }
        }
    }

    private func historyVersionButton(_ version: EnhancedPhoto) -> some View {
        let selected = showOriginal ? isRetainedSource(version) : version.id == viewed.id
        return Button {
            chooseVersion(version)
            showVersionHistory = false
        } label: {
            HStack(spacing: 12) {
                DetailPhotoThumb(url: version.enhancedURL, height: 64)
                    .frame(width: 80).accessibilityHidden(true)
                Text(version.savedVersion?.title ?? "Earlier version")
                    .font(.body).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("photoVersion.history.version." + version.id)
    }

    private func savedVersionStrip(stacked: Bool) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 8), count: stacked ? 1 : 2), spacing: 8) {
            if viewed.originalURL != viewed.enhancedURL && !versionChoices.contains(where: isRetainedSource) {
                versionChip(viewed.retainedSourceIsVerified ? "Original" : "Earlier source", selected: showOriginal) {
                    showOriginal = true
                }
            }
            ForEach(versionChoices) { version in
                versionChip(choiceTitle(version), selected: showOriginal ? isRetainedSource(version) : choiceTitle(viewed) == choiceTitle(version)) {
                    chooseVersion(version)
                }
            }
        }.accessibilityIdentifier("photoVersion.savedChoices")
    }

    private var reviewDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !showOriginal, needsStagingReview || needsCustomReview {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Review before using on the listing", systemImage: "checkmark.shield")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                    Text("Compare with the source, then confirm the checks below.")
                        .font(.caption).foregroundStyle(Theme.inkDim)
                    if needsStagingReview { stagingReviewChecklist }
                    if needsCustomReview { customReviewChecklist }
                }
                .padding(14)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            if !showOriginal, (viewed.savedVersion?.effects.contains("stage") == true || needsCustomReview),
               imageLoadComplete && (original == nil || viewed.originalURL == viewed.enhancedURL) {
                Label("Restore the retained source before selecting this version.", systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(Theme.warn).fixedSize(horizontal: false, vertical: true)
            }
            if (!showOriginal && savedDisclosure?.isEmpty == false) || viewed.savedVersion?.sourceHistoryKnown != true {
                DisclosureGroup("About this version") {
                    VStack(alignment: .leading, spacing: 8) {
                        if !showOriginal, let savedDisclosure, !savedDisclosure.isEmpty {
                            Text(savedDisclosure)
                        }
                        if viewed.savedVersion?.sourceHistoryKnown != true {
                            Text("Earlier edits are unverified. This source may already contain AI changes.")
                        }
                        if !showOriginal, viewed.savedVersion?.effects.contains("stage") == true {
                            Text("Check windows, doors, fixed appliances and furniture across views. AI can change details.")
                        }
                    }.font(.caption).foregroundStyle(Theme.inkDim).padding(.top, 6)
                }.font(.subheadline).foregroundStyle(Theme.ink)
            }
            // Optional feedback on this exact AI version. It sits after the
            // required checks and never changes them or any action above.
            if !dynamicTypeSize.isAccessibilitySize, !showOriginal,
               let feedbackVersion = viewed.savedVersion, PhotoFeedbackQueue.shared.canRecord(feedbackVersion) {
                PhotoFeedbackControl(version: feedbackVersion, directory: viewed.enhancedURL.deletingLastPathComponent(),
                                     cloudListing: isCloudListing, listingSelected: publicationSelected,
                                     exportOpened: exporting != nil, onRevealReasons: { versionID in
                                         guard !showOriginal, viewed.savedVersion?.id == versionID else { return }
                                         feedbackReasonReveal = FeedbackReasonReveal(versionID: versionID)
                                     })
                    .id(feedbackVersion.id)
            }
        }.accessibilityIdentifier("photoVersion.reviewControls")
    }

    private func actionFooter(stacked: Bool) -> some View {
        Group {
            if stacked {
                VStack(spacing: 8) { savePhotoButton; useOnListingButton }
            } else {
                HStack(spacing: 10) { savePhotoButton; useOnListingButton }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 0.5) }
        .accessibilityIdentifier("photoVersion.fixedActions")
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: PhotoReviewFooterHeightPreferenceKey.self, value: proxy.size.height)
            }
        }
    }

    @ViewBuilder private var useOnListingButton: some View {
        if !showOriginal, viewed.savedVersion != nil {
            PrimaryButton(title: selectionWorkID != nil ? "Checking…" : isCloudListing && !cloudSelectionKnown ? "Check selection" : cloudCoverRequested ? "Use as cover" : publicationSelected ? "Unselect" : "Use on listing",
                          systemImage: publicationSelected ? "minus.circle" : "checkmark.circle",
                          isDisabled: listingSelectionDisabled, action: changeListingSelection)
            .frame(minHeight: 44)
            .accessibilityIdentifier("photoVersion.useOnListing")
            .accessibilityLabel(isCloudListing && !cloudSelectionKnown ? "Refresh listing photo selection" : cloudCoverRequested ? "Use this version as the listing cover" : publicationSelected ? "Remove this photo from listing" : "Use this version on listing")
            .accessibilityHint(publicationSelected ? "Keeps every original and saved edit in Photos." : "Checks this home’s current cloud selection before changing it.")
            .disabled(listingSelectionDisabled)
        }
    }

    private var listingSelectionDisabled: Bool {
        guard imageContext?.isCurrent == true, selectionWorkID == nil else { return true }
        if isCloudListing && !cloudSelectionKnown { return false } // Refresh only, never an ambiguous mutation.
        // Removing exposure does not require decoded pixels or a new approval.
        if publicationSelected && !cloudCoverRequested { return false }
        return enhanced == nil
            || ((viewed.savedVersion?.effects.contains("stage") == true || needsCustomReview)
                && (original == nil || viewed.originalURL == viewed.enhancedURL
                    || (needsStagingReview && !stagingReview.isComplete)
                    || (needsCustomReview && !customReview.isComplete)))
    }

    private func changeListingSelection() {
        guard imageContext?.isCurrent == true else { clearAndDismiss(); return }
        guard selectionWorkID == nil else { return }
        do {
            let directory = viewed.enhancedURL.deletingLastPathComponent()
            guard let listingID = UUID(uuidString: directory.lastPathComponent) else { return }
            if model.listings.first(where: { $0.id == listingID })?.serverID != nil {
                if cloudCoverRequested { beginCloudSelection(followCover: false) }
                else if cloudSelectionKnown, !publicationSelected,
                   let family = viewed.savedVersion?.familyID,
                   cloudProjection?.versions.contains(where: { $0.familyID == family && cloudProjection?.coverVersionIDs.contains($0.id) == true }) == true {
                    confirmCloudCoverFollow = true
                } else { beginCloudSelection(followCover: false) }
                return
            }
            try PhotoVersionHistory.trackExisting(id: viewed.id, imageFile: viewed.enhancedURL.lastPathComponent,
                priorFile: viewed.originalURL == viewed.enhancedURL ? nil : viewed.originalURL.lastPathComponent, directory: directory)
            let currentSelection = try PhotoVersionHistory.load(directory: directory).isSelectedForListing(viewed.id)
            guard currentSelection == selectedForListing else {
                selectedForListing = currentSelection
                throw PhotoVersionHistory.Failure.changedVersion
            }
            let priorMain = model.listings.first { $0.id == listingID }?.mainPhotoRelPath
            let familyWasMain = try PhotoVersionHistory.familyContains(id: viewed.id,
                imageFile: priorMain.map { FileStore.url(fromRelativePath: $0).lastPathComponent }, directory: directory)
            if currentSelection {
                try PhotoVersionHistory.removeFromPublication(id: viewed.id, directory: directory)
                if familyWasMain {
                    let replacement = try PhotoVersionHistory.availableCoverVersion(directory: directory)
                    model.setMainPhoto(replacement.map { FileStore.relativePath(for: directory.appendingPathComponent($0.imageFile)) }, for: listingID)
                }
                selectedForListing = false
            } else {
                guard !needsStagingReview || stagingReview.isComplete else {
                    throw PhotoVersionHistory.Failure.reviewRequired
                }
                guard !needsCustomReview || customReview.isComplete else {
                    throw PhotoVersionHistory.Failure.customReviewRequired
                }
                try PhotoVersionHistory.selectForPublication(id: viewed.id, directory: directory,
                    reviewed: stagingReview.isComplete, customReviewed: customReview.isComplete)
                if familyWasMain || requestedCoverForViewed { model.setMainPhoto(FileStore.relativePath(for: viewed.enhancedURL), for: listingID) }
                selectedForListing = true
            }
            if let listing = model.listings.first(where: { $0.id == listingID }),
               listing.serverShareURL != nil, let serverID = listing.serverID {
                Task { await model.syncGalleryPhotos(listingLocalID: listingID, listingServerID: serverID) }
            }
        } catch { selectionError = error.localizedDescription }
    }

    private func beginCloudSelection(followCover: Bool) {
        guard let listingID = photoListingID, let context = imageContext, context.isCurrent,
              selectionWorkID == nil else { return }
        let versionID = viewed.id, wasSelected = publicationSelected, known = cloudSelectionKnown
        let work = UUID(); selectionWorkID = work
        Task { @MainActor in
            defer { if selectionWorkID == work { selectionWorkID = nil } }
            do {
                guard context.isCurrent, viewed.id == versionID else { throw PhotoCloudSelectionFailure.identityChanged }
                if !known {
                    _ = try await model.refreshCloudPhotoSelection(listingID: listingID)
                    return
                }
                if !wasSelected || cloudCoverRequested {
                    guard !needsStagingReview || stagingReview.isComplete else { throw PhotoVersionHistory.Failure.reviewRequired }
                    guard !needsCustomReview || customReview.isComplete else { throw PhotoVersionHistory.Failure.customReviewRequired }
                }
                let reviewed = (!needsStagingReview || stagingReview.isComplete) && (!needsCustomReview || customReview.isComplete)
                // Optional feedback signals describe this exact request after it succeeds.
                let feedbackVersion = viewed.savedVersion, choosing = !wasSelected || cloudCoverRequested
                let stagingAcknowledged = needsStagingReview && stagingReview.isComplete
                let customAcknowledged = needsCustomReview && customReview.isComplete
                if cloudCoverRequested {
                    _ = try await model.makeCloudPhotoCover(listingID: listingID, versionID: versionID, reviewed: reviewed)
                } else {
                    _ = try await model.changeCloudPhotoSelection(listingID: listingID, versionID: versionID,
                        selecting: !wasSelected, followFamilyCover: followCover, reviewed: reviewed)
                }
                guard context.isCurrent, viewed.id == versionID else { throw PhotoCloudSelectionFailure.identityChanged }
                if choosing {
                    PhotoFeedbackQueue.shared.recordListingSelection(of: feedbackVersion, stagingAcknowledged: stagingAcknowledged,
                        customAcknowledged: customAcknowledged,
                        listingIsLive: model.listings.first(where: { $0.id == listingID })?.serverShareURL != nil)
                }
            } catch { if context.isCurrent, selectionWorkID == work { selectionError = error.localizedDescription } }
        }
    }

    private func abandonSavedCloudSelection() {
        guard let listingID = photoListingID, let context = imageContext, context.isCurrent,
              selectionWorkID == nil, cloudProjection?.pending == true else { return }
        let work = UUID(); selectionWorkID = work
        Task { @MainActor in
            defer { if selectionWorkID == work { selectionWorkID = nil } }
            do { _ = try await model.abandonCloudPhotoSelection(listingID: listingID) }
            catch { if context.isCurrent, selectionWorkID == work { selectionError = error.localizedDescription } }
        }
    }

    private var savePhotoButton: some View {
        SecondaryButton(title: "Save photo", systemImage: "square.and.arrow.down", isDisabled: savePhotoDisabled) {
            guard imageContext?.isCurrent == true else { clearAndDismiss(); return }
            do {
                if !showOriginal, needsCustomReview {
                    guard enhanced != nil, original != nil, viewed.originalURL != viewed.enhancedURL else {
                        throw PhotoVersionHistory.Failure.missingImage
                    }
                    try PhotoVersionHistory.confirmCustomReview(id: viewed.id,
                        imageFile: viewed.enhancedURL.lastPathComponent,
                        sourceFile: viewed.originalURL.lastPathComponent, review: customReview,
                        directory: viewed.enhancedURL.deletingLastPathComponent())
                }
                exporting = PhotoExportSelection(photos: [viewed], original: showOriginal)
            } catch { selectionError = error.localizedDescription }

        }
        .frame(minHeight: 44)
        .accessibilityIdentifier("photoVersion.download")
        .accessibilityLabel(showOriginal ? (viewed.retainedSourceIsVerified ? "Download original" : "Download earlier source")
            : "Download " + choiceTitle(viewed).lowercased() + " photo")
        .disabled(savePhotoDisabled)
    }

    private var savePhotoDisabled: Bool {
        imageContext?.isCurrent != true || (showOriginal ? original == nil : enhanced == nil || (needsCustomReview
            && (original == nil || viewed.originalURL == viewed.enhancedURL || !customReview.isComplete)))
    }

    private func chooseVersion(_ version: EnhancedPhoto) {
        if version.id == viewed.id {
            showOriginal = false
            return
        }
        showFullComparison = false
        imageContext = nil
        enhanced = nil
        original = nil
        imageLoadComplete = false
        selectedVersion = version
        showOriginal = false
    }

    private func clearAndDismiss() {
        showAccessibilityFeedback = false
        showFullComparison = false
        exporting = nil
        clearSinglePhotoEdit()
        imageContext = nil
        selectionWorkID = nil
        enhanced = nil
        original = nil
        dismiss()
    }

    private func finishSinglePhotoSetup() {
        if singleEditJobID == nil, singleStagingSetup == nil, singleCustomPhoto == nil { clearSinglePhotoEdit() }
    }

    private func clearSinglePhotoEdit() {
        singleDeclutterReview?.cancel(); singleDeclutterReview = nil
        showEditActions = false
        pendingEdit = nil
        singleStagingSetup = nil
        singleCustomPhoto = nil
        editContext = nil
        editConsentRevision = nil
        editOriginal = nil
        singleEditJobID = nil
        editConnection.cancel()
    }

    private var stagingReviewChecklist: some View {
        VStack(alignment: .leading, spacing: 2) {
            comparisonStatus(stagingReview.comparedSource)
            reviewCheck("Windows, walls and fixtures match", detail: "Windows, walls and fixed appliances match the source", isOn: $stagingReview.fixedFeaturesMatch)
            reviewCheck("Doors and routes stay clear", detail: "Doors, exits and walking routes remain clear", isOn: $stagingReview.accessIsClear)
            reviewCheck("Furniture matches across views", detail: "Furniture matches my other published views, or this is the only view", isOn: $stagingReview.furnitureMatchesOtherViews)
        }.accessibilityIdentifier("photoVersion.stagingReview")
    }

    private var customReviewChecklist: some View {
        VStack(alignment: .leading, spacing: 2) {
            comparisonStatus(customReview.comparedSource)
            reviewCheck("Fixed features match", detail: "Structure and fixed features match the source", isOn: $customReview.fixedFeaturesMatch)
            reviewCheck("Colors and materials match", detail: "Paint colors, garage door, trim and materials match", isOn: $customReview.colorsAndMaterialsMatch)
            reviewCheck("Only my requested change", detail: "Only the change I requested was made", isOn: $customReview.onlyRequestedChange)
        }.accessibilityIdentifier("photoVersion.customReview")
    }

    private func comparisonStatus(_ compared: Bool) -> some View {
        Label(compared ? "Source comparison opened" : "Open Compare and view the source first",
              systemImage: compared ? "checkmark.circle.fill" : "square.split.2x1")
            .font(.caption).foregroundStyle(compared ? Theme.good : Theme.inkDim)
            .padding(.bottom, 4)
    }

    private func reviewCheck(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            HStack(spacing: 10) {
                Image(systemName: isOn.wrappedValue ? "checkmark.circle.fill" : "circle")
                    .font(.title3).foregroundStyle(isOn.wrappedValue ? Theme.accent : Theme.inkDim)
                Text(title).font(.subheadline).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(detail)
        .accessibilityValue(isOn.wrappedValue ? "Confirmed" : "Not confirmed")
        .accessibilityAddTraits(isOn.wrappedValue ? .isSelected : [])
    }

    private func versionChip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(selected ? Theme.accent : Theme.fillSubtle, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .foregroundStyle(selected ? Color.white : Theme.ink)
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Inspection only: choosing the source records comparison in the parent, but
/// this screen has no publication, approval or export actions.
private struct PhotoFullSizeComparison: View {
    let edited: UIImage
    let source: UIImage?
    let sourceTitle: String
    @Binding var showOriginal: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1

    private var image: UIImage { showOriginal ? (source ?? edited) : edited }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(showOriginal ? sourceTitle : "Edited photo").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.accessibilityIdentifier("photoComparison.close")
            }.padding(.horizontal)
            if source != nil {
                Picker("Photo version", selection: $showOriginal) {
                    Text("Edited").tag(false)
                    Text(sourceTitle).tag(true)
                }.pickerStyle(.segmented).padding(.horizontal)
                    .accessibilityIdentifier("photoComparison.version")
            }
            GeometryReader { geometry in
                let scale = min(geometry.size.width / max(1, image.size.width),
                                geometry.size.height / max(1, image.size.height))
                let magnification = min(5, max(1, zoom * pinch))
                ScrollView([.horizontal, .vertical]) {
                    Image(uiImage: image).resizable()
                        .frame(width: image.size.width * scale * magnification,
                               height: image.size.height * scale * magnification)
                        .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                        .accessibilityLabel(showOriginal ? sourceTitle : "Edited photo")
                        .accessibilityIdentifier("photoComparison.image")
                }
                .gesture(MagnificationGesture().updating($pinch) { value, state, _ in state = value }
                    .onEnded { value in zoom = min(5, max(1, zoom * value)) })
            }
            HStack {
                Text("Pinch to zoom. Swipe to inspect details.").font(.caption)
                Spacer()
                Button("Reset zoom") { zoom = 1 }.font(.caption)
            }.padding(.horizontal)
        }
        .foregroundStyle(Theme.ink).padding(.vertical)
        .background(Theme.bg.ignoresSafeArea())
        .onChange(of: showOriginal) { _ in zoom = 1 }
    }
}

/// Free-text AI edit — describe any change and it runs through the same
/// `ai-photo` path as the presets (`edit: "custom"`, prompt capped at 600
/// chars, matching the server). Inline here per the new-file-not-in-target rule.
struct CustomEditSheet: View {
    let photo: EnhancedPhoto             // the photo this prompt will edit
    let api: APIClient                   // snapshot from the presenting view
    /// The business type the examples speak in — a gym's starter ideas are not
    /// a restaurant's. Passed in because this sheet has no listing of its own.
    let space: SpaceType
    /// The listing's SERVER id when it has one, so the prompt rewrite is gated
    /// against this listing's real space type rather than the strictest rules.
    /// nil is supported and simply fails closed.
    let listingServerID: UUID?
    let onGenerate: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var prompt = ""
    @StateObject private var connection = FeatureSessionAction()
    @State private var isImproving = false       // "Improve my prompt" in flight
    @State private var improveError: String?
    /// The area named by the starter chip the person tapped, sent as
    /// `room_hint`. See `StarterChip` for why this is the room signal we have.
    @State private var pickedArea: String?
    @State private var needsClarification = false
    @State private var preparedPrompt: String?
    @State private var chosenScope: CustomPhotoPromptPolicy.Choice?

    private var trimmed: String {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
              VStack(alignment: .leading, spacing: 14) {
                Text("Tell us what to change. You'll review the instruction first, then compare the result with your saved source.")
                    .font(.rpBody)
                    .foregroundStyle(Theme.inkDim)

                TextField("For example: improve brightness and keep the existing paint colors",
                          text: $prompt, axis: .vertical)
                    .lineLimit(4...8)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("customPhoto.request")

                Text("\(prompt.count)/600")
                    .font(.rpCaption)
                    .foregroundStyle(prompt.count >= 600 ? Theme.warn : Theme.inkDim)
                    .frame(maxWidth: .infinity, alignment: .trailing)

                starterChipsRow

                // Rough idea in → sharper prompt back (replaces the field text;
                // still fully editable before Generate).
                Button { improvePrompt() } label: {
                    HStack(spacing: 8) {
                        if isImproving {
                            ProgressView().tint(Theme.accent)
                            Text("Improving your prompt…")
                        } else {
                            Text("✨ Improve my prompt")
                        }
                    }
                    .font(.rpBody.weight(.semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 13)
                    .modifier(RendpropActionLabelSurface(primary: false))
                }
                .disabled(trimmed.isEmpty || isImproving)
                Text("Optional: refine your whole request before reviewing it. Uses your AI allowance.")
                    .font(.rpCaption)
                    .foregroundStyle(Theme.inkDim)

                if let improveError {
                    Text(improveError)
                        .font(.rpCaption)
                        .foregroundStyle(Theme.warn)
                }

                if needsClarification {
                    Text("What would you like us to change?")
                        .font(.rpBody.weight(.semibold))
                    Text("Your request is still above. Pick one specific change so we don't guess what you meant.")
                        .font(.rpCaption).foregroundStyle(Theme.inkDim)
                    ForEach(CustomPhotoPromptPolicy.Choice.allCases) { choice in
                        Button(choice.label) {
                            chosenScope = choice
                            preparedPrompt = choice.prompt
                            needsClarification = false
                            improveError = nil
                        }.font(.rpBody.weight(.semibold))
                            .accessibilityIdentifier("customPhoto.choice.\(choice.id)")
                    }
                }

                if let preparedPrompt {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Review your edit").font(.rpBody.weight(.semibold))
                        if let chosenScope { Text("We'll only: \(chosenScope.label.lowercased()).").font(.rpCaption) }
                        Text(preparedPrompt).font(.rpBody)
                            .accessibilityIdentifier("customPhoto.preparedInstruction")
                        Text(CustomPhotoPromptPolicy.preservedFeatures).font(.rpCaption).foregroundStyle(Theme.inkDim)
                        Text("AI can still make mistakes. The result is saved as a preview until you compare and approve it for your listing.")
                            .font(.rpCaption).foregroundStyle(Theme.inkDim)
                    }.padding().background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 12))
                    Button {
                        guard CustomPhotoPromptPolicy.decision(for: preparedPrompt, realEstate: space == .realEstate) == .ready else {
                            reviewEdit(); return
                        }
                        Haptics.selection()
                        dismiss()
                        onGenerate(preparedPrompt)
                    } label: {
                        Label("Generate preview", systemImage: "wand.and.stars")
                        .font(.rpBody.weight(.semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .modifier(RendpropActionLabelSurface(primary: true))
                    }.disabled(isImproving).accessibilityIdentifier("customPhoto.generatePreview")
                    Button("Choose a different change") {
                        self.preparedPrompt = nil; chosenScope = nil; needsClarification = true
                    }.font(.rpCaption)
                } else if !needsClarification {
                    Button { reviewEdit() } label: {
                        Label("Review edit", systemImage: "text.magnifyingglass")
                            .font(.rpBody.weight(.semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                            .modifier(RendpropActionLabelSurface(primary: true))
                    }.disabled(trimmed.isEmpty || isImproving).accessibilityIdentifier("customPhoto.reviewEdit")
                }
              }.padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .disabled(connection.isWaiting)
            .background(Theme.bg)
            .navigationTitle("Custom AI edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onChange(of: prompt) { newValue in
                if newValue.count > 600 { prompt = String(newValue.prefix(600)) }
                preparedPrompt = nil; chosenScope = nil; needsClarification = false; improveError = nil
                // An emptied box means the starter chip that named an area is
                // gone too: whatever gets typed next may be about a different
                // room, and a stale `room_hint` is worse than none.
                if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    pickedArea = nil
                }
            }
        }
        .sessionConnectionNotice(isActive: connection.isWaiting, onCancel: { connection.cancel() })
        .onDisappear { connection.cancel() }
        .presentationDetents([.large])
    }

    private func reviewEdit() {
        switch CustomPhotoPromptPolicy.decision(for: trimmed, realEstate: space == .realEstate) {
        case .ready:
            preparedPrompt = trimmed; needsClarification = false; improveError = nil
        case .clarify:
            preparedPrompt = nil; needsClarification = true; improveError = nil
        case .blocked:
            preparedPrompt = nil; needsClarification = false
            improveError = CustomPhotoPromptPolicy.blockedMessage
        }
    }

    // MARK: Starter chips — somewhere to begin when the box is empty

    /// One tappable example instruction.
    ///
    /// `area` is the room or area the example is about, and it rides along as
    /// `room_hint` when the person then asks for a better prompt. It is the
    /// ONLY room signal this screen has: the photos in the studio are imported
    /// files with no tag of their own, and the walkthrough's room tags are
    /// anchored to a TIMELINE (`RoomTag.tMs`) rather than to any still. If a
    /// photo ever carries its own tag, that becomes the better source and this
    /// stays as the fallback for a typed idea.
    struct StarterChip: Identifiable, Hashable {
        /// What the capsule says. Short — it has to fit on a phone.
        let label: String
        /// The area this example is about; nil when it is about the whole shot.
        let area: String?
        /// What tapping it puts in the field. A whole, specific instruction —
        /// the point is to show what "specific" looks like.
        let text: String
        var id: String { label }
    }

    /// Examples in the vocabulary of THIS business type. Drawn from the same
    /// area names the room tagger offers (`SpaceType.quickTags`) and the detail
    /// fields the owner already filled in for their industry, so the words are
    /// ones they use — a gym racks weights, a store faces shelves.
    ///
    /// Deliberately NOT the preset edits: twilight, sky, lawn, declutter and
    /// staging are buttons of their own one screen back. These are the things
    /// only free text can ask for.
    ///
    /// `nonisolated` because it is pure and is read from a view property, not
    /// from `body`.
    nonisolated static func starterChips(for space: SpaceType) -> [StarterChip] {
        switch space {
        case .realEstate:
            return [
                StarterChip(label: "Clear the counters", area: "Kitchen",
                            text: "Remove loose items from the kitchen counters. Keep the cabinets, appliances, existing materials, paint colors and actual property condition as photographed."),
                StarterChip(label: "Brighter photo", area: nil,
                            text: CustomPhotoPromptPolicy.Choice.lighting.prompt),
                StarterChip(label: "Warm evening light", area: "Living Room",
                            text: "Relight the room with warm evening light coming through the windows, keeping the furniture and the architecture exactly as photographed."),
                StarterChip(label: "Tidy the yard", area: "Backyard",
                            text: "Remove the hose, bins and loose items from the yard. Keep the house, planting, materials and actual property condition as photographed."),
                StarterChip(label: "Empty the driveway", area: "Exterior",
                            text: "Remove movable cars and bins from the driveway and the street in front, keeping the house and actual property condition as photographed."),
            ]
        case .venue:
            return [
                StarterChip(label: "Set it for an event", area: "Main Hall",
                            text: "Set the room for an evening event: round tables, linens and chairs neatly placed, keeping the room's architecture and fixtures exactly as photographed."),
                StarterChip(label: "Warm up the lighting", area: "Main Hall",
                            text: "Relight the room with warm evening lighting and a soft glow on the walls, keeping every fixture exactly as photographed."),
                StarterChip(label: "Clear the clutter", area: nil,
                            text: "Remove the stacked chairs, cables and boxes from the shot, keeping the room exactly as photographed."),
                StarterChip(label: "Dress the patio", area: "Patio",
                            text: "Dress the patio for a summer evening with string lights and set tables, keeping the building and the planting exactly as photographed."),
            ]
        case .restaurant:
            return [
                StarterChip(label: "Set the tables", area: "Dining",
                            text: "Set the dining tables with clean linens, glassware and cutlery, keeping the room's layout and fixtures exactly as photographed."),
                StarterChip(label: "Warm dinner light", area: "Dining",
                            text: "Relight the room for dinner service — warm, low light with a glow over each table — keeping every fixture exactly as photographed."),
                StarterChip(label: "Tidy the bar", area: "Bar",
                            text: "Clear the bar top and straighten the bottles and glassware behind it, keeping the bar exactly as photographed."),
                StarterChip(label: "Dress the patio", area: "Patio",
                            text: "Dress the patio for an evening with string lights and set tables, keeping the building and the planting exactly as photographed."),
            ]
        case .retail:
            return [
                StarterChip(label: "Face the shelves", area: "Aisles",
                            text: "Straighten and face every product on the shelves so the aisle looks freshly stocked, keeping the fixtures and the signage exactly as photographed."),
                StarterChip(label: "Fresh produce", area: "Produce",
                            text: "Make the produce look freshly stocked and glistening, keeping the display and the store exactly as photographed."),
                StarterChip(label: "Clear the checkout", area: "Checkout",
                            text: "Clear the clutter from the checkout counter and tidy the racks beside it, keeping the fixtures exactly as photographed."),
                StarterChip(label: "Brighter aisles", area: "Aisles",
                            text: "Brighten the aisle lighting so the shelves read clearly, keeping the colors true and the fixtures exactly as photographed."),
            ]
        case .fitness:
            return [
                StarterChip(label: "Rack the weights", area: "Weights",
                            text: "Rack every loose weight and clear the floor, keeping the equipment and the room exactly as photographed."),
                StarterChip(label: "Wipe it down", area: "Main Floor",
                            text: "Make the floor and the equipment look freshly cleaned, keeping every machine exactly where it is."),
                StarterChip(label: "Brighter floor", area: "Main Floor",
                            text: "Brighten the room so the whole floor reads clearly, keeping the colors true and the equipment exactly as photographed."),
                StarterChip(label: "Tidy the lockers", area: "Locker Room",
                            text: "Clear the benches and close the locker doors so the room looks freshly cleaned, keeping the fixtures exactly as photographed."),
            ]
        case .other:
            return [
                StarterChip(label: "Clear the clutter", area: "Main Area",
                            text: "Remove the boxes, cables and loose items from the shot, keeping the room exactly as photographed."),
                StarterChip(label: "Brighter photo", area: nil,
                            text: CustomPhotoPromptPolicy.Choice.lighting.prompt),
                StarterChip(label: "Warm evening light", area: "Main Area",
                            text: "Relight the room with warm evening light, keeping the furniture and the architecture exactly as photographed."),
                StarterChip(label: "Tidy the entrance", area: "Entrance",
                            text: "Tidy the entrance: clear the signage clutter and make the glass and the floor look freshly cleaned, keeping the building exactly as photographed."),
            ]
        }
    }

    /// The examples, shown ONLY while the box is empty.
    ///
    /// That is the whole problem they solve — "Ask for anything" opened onto a
    /// blank field and a 600-char counter, which tells a person how much room
    /// they have and nothing about what to put in it. Once there are words on
    /// screen the next move is "Improve my prompt", and a row of examples under
    /// a half-typed sentence is just noise. Hiding them also means a tap can
    /// only ever fill an EMPTY field, so no chip can destroy something typed.
    @ViewBuilder private var starterChipsRow: some View {
        if trimmed.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Not sure what to ask for? Start with one of these and edit it.")
                    .font(.rpCaption)
                    .foregroundStyle(Theme.inkDim)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Self.starterChips(for: space)) { chip in
                            starterChipButton(chip)
                        }
                    }
                    .padding(.vertical, 1)   // so the capsules aren't clipped
                }
            }
        }
    }

    private func starterChipButton(_ chip: StarterChip) -> some View {
        Button { fill(with: chip) } label: {
            Text(chip.label)
                .font(.rpCaption.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Theme.accentSoft, in: Capsule())
        }
        .buttonStyle(ScalePressStyle())
        .disabled(isImproving)
        .accessibilityLabel(Text("\(chip.label). Puts an example in the box that you can edit."))
    }

    private func fill(with chip: StarterChip) {
        prompt = String(chip.text.prefix(600))
        pickedArea = chip.area
        Haptics.selection()
    }

    /// Send the rough idea through `ai-copy/edit-prompt` and REPLACE the field
    /// with the sharper version. The user can still edit before Generate; the
    /// 600-char cap stays enforced by onChange above.
    ///
    /// NO PHOTO IS ENCODED. This used to base64 a 1024 px JPEG first and hand
    /// it over — but `improve_prompt` has been text-only on the server since
    /// audit F-E-16, and `LiveAPIClient` was already dropping the bytes on the
    /// floor. That left a multi-megabyte encode running on the main path of the
    /// one AI call in the app that is meant to feel instant.
    private func improvePrompt() {
        guard CustomPhotoPromptPolicy.decision(for: trimmed, realEstate: space == .realEstate) == .ready else {
            reviewEdit(); return
        }
        guard !trimmed.isEmpty, !isImproving else { return }
        connection.run { improvePromptWithSession() }
    }

    private func improvePromptWithSession() {
        let rough = trimmed
        guard !rough.isEmpty, !isImproving else { return }
        isImproving = true
        improveError = nil
        Haptics.selection()
        let api = self.api
        let hint = pickedArea            // nil unless a starter chip named an area
        let serverID = listingServerID
        let spaceRaw = space.rawValue
        Task {
            do {
                let improved = try await api.aiImprovePrompt(rough: rough,
                                                             roomHint: hint,
                                                             listingServerID: serverID)
                guard improved.count <= 600 else { throw APIError.decoding }
                let text = improved
                await MainActor.run {
                    prompt = text
                    isImproving = false
                    Haptics.success()
                    // No prompt text and no photo id in the props — a length and
                    // an enum, per Analytics.swift's rule.
                    Analytics.track("ai_prompt_improved",
                                    ["space_type": spaceRaw,
                                     "chars": String(text.count),
                                     "ok": "true"])
                }
            } catch {
                let why = AIFailure(error).fullMessage
                let asksClarification = (error as? APIError)?.code == "photo_clarification_required"
                await MainActor.run {
                    isImproving = false
                    improveError = why
                    if asksClarification {
                        preparedPrompt = nil; chosenScope = nil; needsClarification = true
                    }
                    // Deliberately NO reason prop: the server's message is
                    // written for a person and can quote their own words back.
                    Analytics.track("ai_prompt_improved",
                                    ["space_type": spaceRaw, "ok": "false"])
                }
            }
        }
    }
}

// MARK: - AI edit suggestions ("what would help this photo")
// Inline here per the new-file-not-in-target rule.

/// Payload for the suggestions sheet — the analyzed photo + its results.
struct SuggestResult: Identifiable {
    let id = UUID()
    let photo: EnhancedPhoto
    let suggestions: [AIEditSuggestion]
}

/// AI "suggest edits" results — up to three preset edits, each a tappable row
/// (friendly name + reason + a confidence dot) that runs the normal aiEdit
/// path in the presenting PhotoStudioView. Empty = the photo already looks good.
struct SuggestSheet: View {
    let suggestions: [AIEditSuggestion]
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    /// edit key → the same user-facing names the wand dialog uses.
    private static func friendlyName(_ edit: String) -> String {
        switch edit {
        case "twilight":  return "Twilight sky"
        case "sky":       return "Blue sky"
        case "lawn":      return "Green lawn"
        case "declutter": return "Declutter"
        case "stage":     return "Virtual staging"
        default:          return edit.capitalized
        }
    }

    private static func icon(_ edit: String) -> String {
        switch edit {
        case "twilight":  return "moon.stars"
        case "sky":       return "cloud.sun"
        case "lawn":      return "leaf"
        case "declutter": return "sparkles.rectangle.stack"
        case "stage":     return "sofa"
        default:          return "wand.and.stars"
        }
    }

    /// Confidence dot: green = strong call, accent = decent, dim = tentative/unknown.
    private static func confidenceColor(_ c: Double?) -> Color {
        guard let c else { return Theme.inkDim }
        if c >= 0.75 { return Theme.good }
        if c >= 0.5 { return Theme.accent }
        return Theme.inkDim
    }

    var body: some View {
        NavigationStack {
            Group {
                if suggestions.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.seal")
                            .font(.system(size: 36, weight: .light))
                            .foregroundStyle(Theme.good)
                        Text("This photo already looks great — try a custom edit.")
                            .font(.rpBody)
                            .foregroundStyle(Theme.inkDim)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 28)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 10) {
                            Text("Tap a suggestion to run it — each edit saves as a new photo.")
                                .font(.rpCaption)
                                .foregroundStyle(Theme.inkDim)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            ForEach(Array(suggestions.enumerated()), id: \.offset) { _, s in
                                row(s)
                            }
                        }
                        .padding()
                    }
                }
            }
            .background(Theme.bg)
            .navigationTitle("Suggested edits")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ s: AIEditSuggestion) -> some View {
        Button {
            Haptics.selection()
            dismiss()
            onPick(s.edit)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: Self.icon(s.edit))
                    .font(.system(size: 17, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 36, height: 36)
                    .background(Theme.accentSoft,
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(Self.friendlyName(s.edit))
                            .font(.rpBody.weight(.semibold))
                            .foregroundStyle(Theme.ink)
                        Circle()
                            .fill(Self.confidenceColor(s.confidence))
                            .frame(width: 7, height: 7)
                            .accessibilityHidden(true)
                    }
                    if !s.reason.isEmpty {
                        Text(s.reason)
                            .font(.rpCaption)
                            .foregroundStyle(Theme.inkDim)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.rpCaption.weight(.bold))
                    .foregroundStyle(Theme.inkDim)
                    .padding(.top, 10)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.fillSubtle, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(ScalePressStyle())
        .accessibilityLabel(Text("\(Self.friendlyName(s.edit)). \(s.reason)"))
    }
}

// MARK: - AI video results (photo→clip)
// Inline in this file (not standalone files) so they're always in the Xcode
// target without re-running xcodegen — see the repo's new-file-not-in-target rule.

/// A finished AI motion clip on disk — Identifiable so it can drive .sheet(item:).
struct AnimatedClip: Identifiable {
    let id = UUID()
    let url: URL
}

/// Small result sheet for a finished photo animation — save/share the clip.
/// "Saved" flips only when the Photos write actually succeeded (F-A-16).
struct AnimatedClipSheet: View {
    let clip: AnimatedClip
    @Environment(\.dismiss) private var dismiss
    @State private var saved = false
    @State private var isSaving = false
    @State private var saveError: String?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Theme.accent)
                .padding(.top, 26)
            Text("Clip ready")
                .font(.rpTitle)
                .foregroundStyle(Theme.ink)
            Text("Your photo is now a 5-second motion clip — perfect for reels and stories. Made with AI motion; the photo itself is unchanged.")
                .font(.rpBody)
                .foregroundStyle(Theme.inkDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button { save() } label: {
                Label(saved ? "Saved to Photos" : "Save to Photos",
                      systemImage: saved ? "checkmark.circle.fill" : "square.and.arrow.down")
                    .font(.rpBody.weight(.semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .modifier(RendpropActionLabelSurface(primary: true))
            }
            .disabled(saved || isSaving)

            if let saveError {
                Text(saveError)
                    .font(.rpCaption)
                    .foregroundStyle(Theme.warn)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            ShareLink(item: clip.url) {
                Label("Share clip", systemImage: "square.and.arrow.up")
                    .font(.rpBody.weight(.semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 13)
                    .modifier(RendpropActionLabelSurface(primary: false))
            }

            Button("Done") { dismiss() }
                .font(.rpBody)
                .foregroundStyle(Theme.inkDim)

            Spacer()
        }
        .padding()
        .background(Theme.bg)
        .presentationDetents([.medium, .large])
    }

    private func save() {
        isSaving = true
        saveError = nil
        let url = clip.url
        Task {
            do {
                try await PhotosLibrarySaver.saveVideo(at: url)
                await MainActor.run {
                    isSaving = false
                    saved = true
                    Haptics.success()
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    saveError = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Aerial intro (AI establishing shot grounded on THIS property)

/// An in-flight aerial job, persisted under `aerial.pending.<listingID>` so a
/// swipe-down, Close, or app switch never loses it: reopening the sheet within
/// two hours resumes polling the same fal job (decision A1 / F-A-05).
private struct PendingAerialJob: Codable {
    var job: AIVideoJob
    var listingID: UUID
    var submittedAt: Date
    var grounded: Bool
    var aspect: String

    static let maxAge: TimeInterval = 2 * 60 * 60

    static func key(_ id: UUID) -> String { "aerial.pending.\(id.uuidString)" }

    static func load(for id: UUID) -> PendingAerialJob? {
        guard let data = UserDefaults.standard.data(forKey: key(id)),
              let pending = try? JSONDecoder().decode(PendingAerialJob.self, from: data) else { return nil }
        guard Date().timeIntervalSince(pending.submittedAt) < maxAge else {
            clear(for: id)
            return nil
        }
        return pending
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.key(listingID))
    }

    static func clear(for id: UUID) {
        UserDefaults.standard.removeObject(forKey: key(id))
    }
}

/// What we know about the listing's stored aerial clip beyond its path: whether
/// it was grounded on the exterior photo and its aspect — so a reopened sheet
/// can label and frame it honestly.
private struct AerialMeta: Codable {
    var grounded: Bool?
    var aspect: String
    /// The exact disclosure sentence the server recorded for this clip, so a
    /// reopened sheet still prints the required wording verbatim rather than
    /// falling back to a generic one (W2-C4). Optional → records written before
    /// the compliance wave still decode.
    var disclosure: String? = nil

    static func key(_ id: UUID) -> String { "aerial.meta.\(id.uuidString)" }

    static func load(for id: UUID) -> AerialMeta? {
        guard let data = UserDefaults.standard.data(forKey: key(id)) else { return nil }
        return try? JSONDecoder().decode(AerialMeta.self, from: data)
    }

    func save(for id: UUID) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.key(id))
    }
}

/// AI aerial "establishing shot" generator (POST /ai-video/aerial). Grounded on
/// THIS property: the exterior photo (image-to-video — the clip starts on the
/// real building and flies out), the region (city/state, never the street),
/// time of day, camera move, format and length. Without a photo the AI invents
/// a generic building of the right space type and the sheet says so.
///
/// The footage is SYNTHETIC — never real drone footage — and the disclosure is
/// visible in every state. The job cannot be lost: the sheet can't be swiped
/// away while generating, Close asks first, the job ids are persisted and
/// resumed on the next open (≤ 2 h), and the screen stays awake. The finished
/// clip lives at Documents/Aerials/<listingID>-<stamp>.mp4 and is attached to
/// the listing (`aerialRelPath`); the previous clip is deleted only after the
/// new one landed. Requires a signed-in account (the job runs on the org).
struct AerialIntroSheet: View {
    @State private var idleHeld = false
    @EnvironmentObject var model: AppModel
    @ObservedObject private var auth = AuthStore.shared
    @Environment(\.dismiss) private var dismiss
    let listing: Listing

    private enum Phase { case form, generating, result }

    private enum TimeOfDay: String, CaseIterable, Identifiable {
        case goldenHour = "golden_hour", midday, twilight, overcast
        var id: String { rawValue }
        var label: String {
            switch self {
            case .goldenHour: return "Golden hour"
            case .midday:     return "Midday"
            case .twilight:   return "Twilight"
            case .overcast:   return "Overcast"
            }
        }
    }

    private enum CameraMove: String, CaseIterable, Identifiable {
        case riseReveal = "rise_reveal", pullBack = "pull_back", orbit, pushIn = "push_in"
        var id: String { rawValue }
        var label: String {
            switch self {
            case .riseReveal: return "Rise & reveal"
            case .pullBack:   return "Pull back"
            case .orbit:      return "Orbit"
            case .pushIn:     return "Push in"
            }
        }
        var blurb: String {
            switch self {
            case .riseReveal: return "Starts on the photo, lifts up and reveals the surroundings."
            case .pullBack:   return "Starts close and drifts backwards to show the whole setting."
            case .orbit:      return "A slow arc around the building."
            case .pushIn:     return "Glides in toward the entrance."
            }
        }
    }

    // The property
    @State private var seeded = false
    @State private var exteriorURL: URL?
    @State private var exteriorVersion = UUID()
    @State private var isSavingPhoto = false
    @State private var photoError: String?
    @State private var region = ""
    // The look
    @State private var timeOfDay: TimeOfDay = .goldenHour
    @State private var motion: CameraMove = .riseReveal
    @State private var portrait = false
    @State private var seconds = 6
    @State private var styleHint = ""
    // The job
    @State private var phase: Phase = .form
    @State private var statusText = "Submitting…"
    @State private var failure: AIFailure?
    @State private var workTask: Task<Void, Never>?
    // The result
    @State private var clipURL: URL?
    @State private var grounded: Bool?
    /// The server's own disclosure sentence for this clip. Nil until a job has
    /// been submitted or a stored clip's meta is read back — `disclosureSentence`
    /// falls back to HousingWire's wording so the required sentence is NEVER
    /// missing from this screen.
    @State private var disclosureText: String?
    @State private var resultPortrait = false
    /// The clip's REAL width ÷ height, read off the file once it is on disk.
    /// Nil until that lands (and again whenever a new clip does).
    @State private var measuredAspect: CGFloat?
    @State private var player: AVPlayer?
    @State private var savedToPhotos = false
    @State private var isSaving = false
    @State private var saveError: String?
    // Presentation
    @StateObject private var connection = FeatureSessionAction()
    @State private var showLibrary = false
    @State private var showCamera = false
    @State private var showCloseConfirm = false
    @State private var showReelStudio = false
    @State private var geocoder = CLGeocoder()

    private var isGenerating: Bool { phase == .generating }
    private var space: SpaceType { listing.isSample ? SpaceType.current : listing.spaceType }
    private var noun: String { space.spaceNoun }
    private var hasPhoto: Bool { exteriorURL != nil }
    private var aspect: String { portrait ? "9:16" : "16:9" }

    /// The shape the RESULT player is drawn at.
    ///
    /// The owner's screenshot for build 9: a flyover sitting in a portrait-ish
    /// box with fat black bars down both sides. That was a display bug and only
    /// a display bug — the clip really is 9:16, the app really did ask for 9:16,
    /// and `/ai-video/aerial` really does forward that aspect to the provider.
    /// What was wrong is that the player was given a fixed HEIGHT (460 tall for
    /// portrait, 220 for wide) across the full width of the sheet, so the box
    /// was about 0.78 wide-to-tall while the clip inside it was 0.5625.
    /// `VideoPlayer` letterboxes the video inside whatever frame it is handed,
    /// so the difference came out as black down both sides. A 16:9 clip in the
    /// 220 pt box had the same problem in the other direction, just smaller.
    ///
    /// So: no fixed height. The container takes the clip's own ratio, measured
    /// from the file, and falls back to the ratio that was REQUESTED at
    /// generation time until that measurement lands — never a jump from a wrong
    /// shape to a right one, just a correction if the two ever disagree. They
    /// can: a grounded aerial is image-to-video built from the agent's exterior
    /// photo, and what a provider returns is not guaranteed to be exactly what
    /// was asked for. Measuring is the only honest answer.
    private var resultAspect: CGFloat {
        measuredAspect ?? (resultPortrait ? 9.0 / 16.0 : 16.0 / 9.0)
    }

    /// The one size limit left, and it is on WIDTH rather than height on
    /// purpose. A 9:16 clip drawn at the full width of the sheet is about 640 pt
    /// tall, which pushes "Save to Photos" off the screen; capping the height
    /// instead would re-create the original bug, because a height cap does not
    /// narrow the box and the clip would letterbox inside it again. Capping the
    /// width at `460 × ratio` is the same statement — "no taller than 460" —
    /// expressed in the axis that keeps the shape exact. For a wide clip the cap
    /// works out far wider than any phone, so it costs nothing there.
    private var resultMaxWidth: CGFloat { 460 * resultAspect }

    /// The clip's displayed width ÷ height, with its preferred transform applied
    /// (a portrait capture is 1920×1080 plus a rotation, not 1080×1920). Same
    /// recipe as `ReelStudioView.isPortraitVideo`, which answers the coarser
    /// version of this question for the reel's format toggle.
    ///
    /// `nonisolated` and `static`: it touches nothing on the view, and the track
    /// loads must not be main-actor work.
    nonisolated private static func displayAspect(of url: URL) async -> CGFloat? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return nil }
        guard let size = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform) else { return nil }
        let rect = CGRect(origin: .zero, size: size).applying(transform)
        let w = abs(rect.width), h = abs(rect.height)
        guard w > 0, h > 0, w.isFinite, h.isFinite else { return nil }
        return w / h
    }

    /// Measure the clip on screen. A failure leaves `measuredAspect` nil, which
    /// falls back to the requested aspect — the same shape build 9 intended.
    private func measureResultAspect() async {
        guard let url = clipURL else { return }
        measuredAspect = await Self.displayAspect(of: url)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.spacing) {
                    header
                    disclosure
                    switch phase {
                    case .form:       formSection
                    case .generating: progressSection
                    case .result:     resultSection
                    }
                    if let failure, phase != .generating {
                        AIFailureCard(failure: failure,
                                      retryHint: "Reopen to check the request already submitted.",
                                      onReconnect: {
                                          if let pending = PendingAerialJob.load(for: listing.id) { resume(pending) }
                                      })
                    }
                }
                .padding()
            }
            .disabled(connection.isWaiting)
            .background(Theme.bg)
            .navigationTitle("Aerial intro")
            .navigationBarTitleDisplayMode(.inline)
            .askAI(.aerial, listingID: listing.id)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        if isGenerating { showCloseConfirm = true } else { dismiss() }
                    }
                }
            }
        }
        .sessionConnectionNotice(isActive: connection.isWaiting, onCancel: { connection.cancel() })
        .interactiveDismissDisabled(isGenerating)
        .onAppear(perform: seedIfNeeded)
        .onDisappear {
            connection.cancel()
            workTask?.cancel()          // the persisted job resumes on the next open
            player?.pause()
            if idleHeld { IdleTimer.release(); idleHeld = false }
        }
        .onChange(of: phase) { p in
            let wantHold = (p == .generating)
            if wantHold && !idleHeld { IdleTimer.hold(); idleHeld = true }
            else if !wantHold && idleHeld { IdleTimer.release(); idleHeld = false }
        }
        .onChange(of: styleHint) { v in
            if v.count > 200 { styleHint = String(v.prefix(200)) }
        }
        .onChange(of: region) { v in
            if v.count > 80 { region = String(v.prefix(80)) }
        }
        .sheet(isPresented: $showLibrary) {
            LibraryImagePicker(selectionLimit: 1, onFailed: { photoError = $0 }) { imgs in
                if let img = imgs.first { saveExterior(img) }
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $showCamera) {
            GuidedPhotoCamera(purpose: .exterior, onPicked: { img in
                let error = await saveExteriorPhoto(img)
                if error == nil { showCamera = false }
                return error
            }, onCancel: { showCamera = false })
            .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $showReelStudio) {
            ReelStudioView(listing: listing,
                           photos: (try? EnhancedPhoto.loadForListing(listingID: listing.id)) ?? [],
                           extraClipURLs: clipURL.map { [$0] } ?? [])
                .environmentObject(model)
        }
        .confirmationDialog("Still generating", isPresented: $showCloseConfirm, titleVisibility: .visible) {
            Button("Close anyway") {
                workTask?.cancel()
                dismiss()
            }
            Button("Keep waiting", role: .cancel) {}
        } message: {
            Text("Your aerial keeps generating in the cloud. Reopen Aerial intro within 2 hours and it picks up where it left off.")
        }
        // Guideline 5.1.2(i) — the exterior photo (when the shot is grounded)
        // and the city/state region go to Google's video models. Agreed once
        // per device before this sheet is usable; declining closes it.
        .aiConsentGate()
        .paywallHost(managesLifecycle: false)
        .task {
            if await AIConsent.shared.ensureGranted() == false { dismiss() }
        }
    }

    // MARK: - Header + disclosure (every state)

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "airplane.departure")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.accent)
            Text("Aerial intro")
                .font(.rpTitle)
                .foregroundStyle(Theme.ink)
            // The "from your photo" promise is only TRUE once a photo is
            // attached — with none, the clip is invented scenery and the
            // headline must not claim otherwise (F-A-03).
            Text(!LaunchFeatureAvailability.canGenerateAerial
                 ? "Coming soon. You can still review saved clips and resume a request already submitted."
                 : (hasPhoto
                    ? "A cinematic AI opening shot for this \(noun) — generated from your exterior photo."
                    : "Add an exterior photo to ground an AI opening shot on this \(noun)."))
                .font(.rpBody)
                .foregroundStyle(Theme.inkDim)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    /// The REQUIRED disclosure sentence for this clip — the server's own wording
    /// when it sent one, otherwise HousingWire's recommended simulated-movement
    /// sentence, which is what the server writes anyway. Never empty: an aerial
    /// is simulated camera movement, and that is exactly the case the disclosure
    /// tests name (and Wisconsin Act 69 covers generated video from 1 Jan 2027).
    private var disclosureSentence: String {
        if let d = disclosureText?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty { return d }
        return AIVideoJob.aerialFallbackDisclosure
    }

    /// Synthetic-footage disclosure — ALWAYS visible, every state, verbatim.
    private var disclosure: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(disclosureSentence, systemImage: "exclamationmark.shield.fill")
                .font(.rpCaption.weight(.semibold))
                .foregroundStyle(Theme.warn)
                .fixedSize(horizontal: false, vertical: true)
            Text("Required disclosure. It is published with your tour and goes out with every share of this clip — this is not real drone footage of this \(noun).")
                .font(.rpCaption)
                .foregroundStyle(Theme.inkDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.fillSubtle, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Form

    // Launch availability never affects recovery of an already accepted job.
    @ViewBuilder private var formSection: some View {
        if !LaunchFeatureAvailability.canGenerateAerial {
            Text(LaunchFeatureAvailability.aerialMessage)
                .font(.rpBody).foregroundStyle(Theme.inkDim)
                .accessibilityIdentifier("aerial.comingSoon")
        } else if listing.isSample {
            sampleNotice
        } else {
            propertyCard
            lookCard
            formatCard
            generateButton
            if clipURL != nil {
                Button("Back to your aerial") { phase = .result }
                    .font(.rpBody)
                    .foregroundStyle(Theme.inkDim)
            }
        }
    }

    private var sampleNotice: some View {
        VStack(spacing: 10) {
            Label("Samples are demos — create a \(noun) first, then generate its aerial.",
                  systemImage: "info.circle")
                .font(.rpBody)
                .foregroundStyle(Theme.inkDim)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 12)
    }

    private var propertyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(space == .realEstate ? "THE PROPERTY" : "THE \(space.spaceNoun.uppercased())")
                .font(.rpKicker).foregroundStyle(Theme.inkDim)
            HStack(alignment: .top, spacing: 12) {
                exteriorThumb
                VStack(alignment: .leading, spacing: 6) {
                    Text(hasPhoto ? "Exterior photo" : "No exterior photo yet")
                        .font(.rpHeadline)
                        .foregroundStyle(Theme.ink)
                    Text(hasPhoto
                         ? "The AI starts on this exact shot and flies out from it."
                         : "Add one so the AI shows YOUR \(noun). Your cover photo is used automatically when you have one.")
                        .font(.rpCaption)
                        .foregroundStyle(Theme.inkDim)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 14) {
                        Button { showLibrary = true } label: {
                            Label("Choose photo", systemImage: "photo")
                        }
                        Button {
                            showCamera = true
                        } label: {
                            Label("Take photo", systemImage: "camera")
                        }
                        .accessibilityIdentifier("aerial.takePhoto")
                    }
                    .font(.rpCaption.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .disabled(isSavingPhoto)
                }
            }
            if isSavingPhoto {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Saving photo…").font(.rpCaption).foregroundStyle(Theme.inkDim)
                }
            }
            if let photoError {
                Text(photoError).font(.rpCaption).foregroundStyle(Theme.warn)
            }
            if !hasPhoto {
                Label("Without a photo the AI invents a generic \(noun) — it won't look like yours.",
                      systemImage: "exclamationmark.triangle")
                    .font(.rpCaption)
                    .foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            Text("REGION").font(.rpKicker).foregroundStyle(Theme.inkDim)
            TextField("City, State — e.g. Charlotte, NC", text: $region)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
            Text("Sets the scenery (skyline, hills, coast). Only the city and state leave your phone — never the street address.")
                .font(.rpCaption)
                .foregroundStyle(Theme.inkDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    @ViewBuilder private var exteriorThumb: some View {
        if let url = exteriorURL {
            DetailPhotoThumb(url: url, height: 96)
                .frame(width: 128)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .id(exteriorVersion)
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.fillSubtle)
                .frame(width: 128, height: 96)
                .overlay(
                    Image(systemName: space.systemImage)
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(Theme.inkDim)
                )
        }
    }

    private var lookCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("TIME OF DAY").font(.rpKicker).foregroundStyle(Theme.inkDim)
            Picker("Time of day", selection: $timeOfDay) {
                ForEach(TimeOfDay.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            Text("CAMERA MOVE").font(.rpKicker).foregroundStyle(Theme.inkDim)
                .padding(.top, 6)
            Picker("Camera move", selection: $motion) {
                ForEach(CameraMove.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(motion.blurb)
                .font(.rpCaption)
                .foregroundStyle(Theme.inkDim)
                .fixedSize(horizontal: false, vertical: true)

            Text("LOOK (OPTIONAL)").font(.rpKicker).foregroundStyle(Theme.inkDim)
                .padding(.top, 6)
            TextField("e.g. warm evening light, light haze, slow and steady",
                      text: $styleHint, axis: .vertical)
                .lineLimit(2...3)
                .textFieldStyle(.roundedBorder)
            Text("\(styleHint.count)/200")
                .font(.rpCaption)
                .foregroundStyle(styleHint.count >= 200 ? Theme.warn : Theme.inkDim)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text(hasPhoto
                 ? "Mood and light only — the building itself comes from your photo."
                 : "Mood and light only. With no exterior photo the AI invents the building too.")
                .font(.rpCaption)
                .foregroundStyle(Theme.inkDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var formatCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("FORMAT").font(.rpKicker).foregroundStyle(Theme.inkDim)
            Picker("Format", selection: $portrait) {
                Text("16:9 · Wide").tag(false)
                Text("9:16 · Reels").tag(true)
            }
            .pickerStyle(.segmented)

            Text("LENGTH").font(.rpKicker).foregroundStyle(Theme.inkDim)
                .padding(.top, 6)
            Picker("Length", selection: $seconds) {
                Text("4s").tag(4)
                Text("6s").tag(6)
                Text("8s").tag(8)
            }
            .pickerStyle(.segmented)
            Text(portrait
                 ? "Vertical — for Reels, TikTok and Stories."
                 : (space == .realEstate
                    ? "Widescreen — for the top of a listing video or YouTube."
                    : "Widescreen — for the top of your tour or YouTube."))
                .font(.rpCaption)
                .foregroundStyle(Theme.inkDim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var generateButton: some View {
        Button { generate() } label: {
            Label(hasPhoto ? "Generate from this photo" : "Generate generic scenery",
                  systemImage: "sparkles")
                .font(.rpBody.weight(.semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .modifier(RendpropActionLabelSurface(primaryFill: hasPhoto ? Theme.actionFill : Theme.warn,
                                                     primaryInk: hasPhoto ? Color.white : Color.black))
        }
        .disabled(isSavingPhoto || !LaunchFeatureAvailability.canGenerateAerial)
        .accessibilityIdentifier("phase1.aerialGenerate")
    }

    // MARK: - Progress

    private var progressSection: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(1.3)
                .padding(.top, 16)
            Text(statusText)
                .font(.rpHeadline)
                .foregroundStyle(Theme.ink)
            Text("Usually 1–3 minutes. The clip downloads the moment it's ready, and the screen stays awake.")
                .font(.rpCaption)
                .foregroundStyle(Theme.inkDim)
                .multilineTextAlignment(.center)
            if let grounded {
                Text(grounded ? "Based on your photo" : "Generic scenery — no exterior photo")
                    .font(.rpCaption.weight(.semibold))
                    .foregroundStyle(grounded ? Theme.accent : Theme.warn)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }

    // MARK: - Result

    private var resultSection: some View {
        VStack(spacing: 12) {
            Label("Aerial ready", systemImage: "checkmark.circle.fill")
                .font(.rpHeadline)
                .foregroundStyle(Theme.good)
            if let grounded {
                Text(grounded ? "Based on your photo" : "Generic scenery — no exterior photo was used")
                    .font(.rpCaption.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(grounded ? Theme.accentSoft : Theme.warn.opacity(0.15), in: Capsule())
                    .foregroundStyle(grounded ? Theme.accent : Theme.warn)
            }
            if let player {
                VideoPlayer(player: player)
                    .aspectRatio(resultAspect, contentMode: .fit)
                    .frame(maxWidth: resultMaxWidth)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                    .onAppear { player.play() }
                    .task(id: clipURL) { await measureResultAspect() }
            }
            if let generatedAt = model.listings.first(where: { $0.id == listing.id })?.aerialGeneratedAt {
                Text("Generated \(generatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.rpCaption)
                    .foregroundStyle(Theme.inkDim)
            }
            if let url = clipURL {
                Button { saveToPhotos(url) } label: {
                    Label(savedToPhotos ? "Saved to Photos" : "Save to Photos",
                          systemImage: savedToPhotos ? "checkmark.circle.fill" : "square.and.arrow.down")
                        .font(.rpBody.weight(.semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .modifier(RendpropActionLabelSurface(primary: true))
                }
                .disabled(savedToPhotos || isSaving)

                // The disclosure travels WITH the clip — an aerial sent by
                // text or email without it is the violation (W2-C4).
                ShareLink(item: url,
                          subject: Text("Aerial intro — \(listing.address)"),
                          message: Text(disclosureSentence)) {
                    Label("Share aerial", systemImage: "square.and.arrow.up")
                        .font(.rpBody.weight(.semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 13)
                        .modifier(RendpropActionLabelSurface(primary: false))
                }
                Button {
                    UIPasteboard.general.string = disclosureSentence
                    Haptics.success()
                } label: {
                    Label("Copy the disclosure", systemImage: "doc.on.doc")
                        .font(.rpCaption.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
                .accessibilityHint(Text("Copies the required disclosure sentence so you can paste it into a caption."))

                Button { showReelStudio = true } label: {
                    Label("Open Reel Studio with this clip", systemImage: "film.stack")
                        .font(.rpBody.weight(.semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 13)
                        .modifier(RendpropActionLabelSurface(primary: false))
                }
            }
            if let saveError {
                Text(saveError)
                    .font(.rpCaption)
                    .foregroundStyle(Theme.warn)
                    .multilineTextAlignment(.center)
            }
            if LaunchFeatureAvailability.canGenerateAerial {
                Button("Regenerate") {
                    failure = nil
                    phase = .form      // the current clip stays until a new one lands
                }
                .font(.rpBody)
                .foregroundStyle(Theme.inkDim)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Seed / resume

    private func seedIfNeeded() {
        guard !seeded else { return }
        seeded = true
        let live = model.listings.first(where: { $0.id == listing.id }) ?? listing
        exteriorURL = live.exteriorPhotoURL
        region = live.regionLabel ?? ""
        if region.trimmingCharacters(in: .whitespaces).isEmpty, !live.isSample,
           let lat = live.latitude, let lon = live.longitude, lat.isFinite, lon.isFinite {
            reverseGeocode(lat: lat, lon: lon)
        }
        let meta = AerialMeta.load(for: listing.id)
        disclosureText = meta?.disclosure
        if let existing = live.aerialURL {
            clipURL = existing
            grounded = meta?.grounded
            resultPortrait = meta?.aspect == "9:16"
            portrait = resultPortrait
            player = AVPlayer(url: existing)
            phase = .result
        }
        if !live.isSample, let pending = PendingAerialJob.load(for: listing.id) {
            resume(pending)
        }
    }

    /// Region label from the cached coordinate (city/state only), stored on the
    /// listing so the next open — and the hosted metadata — has it.
    private func reverseGeocode(lat: Double, lon: Double) {
        let id = listing.id
        geocoder.reverseGeocodeLocation(CLLocation(latitude: lat, longitude: lon)) { marks, _ in
            let mark = marks?.first
            guard let label = FlythroughDetailView.regionLabel(from: mark) else { return }
            let state = FlythroughDetailView.stateCode(from: mark)
            DispatchQueue.main.async {
                if region.trimmingCharacters(in: .whitespaces).isEmpty { region = label }
                model.setRegion(label, stateCode: state, for: id)
            }
        }
    }

    /// Save a chosen/taken exterior photo to Photos/<listingID>/exterior.jpg and
    /// point the listing at it. Encoding runs off the main actor.
    private func saveExterior(_ image: UIImage) {
        Task { _ = await saveExteriorPhoto(image) }
    }

    @MainActor
    private func saveExteriorPhoto(_ image: UIImage) async -> String? {
        guard !isSavingPhoto else { return "Another photo is still saving. Please wait, then try again." }
        isSavingPhoto = true
        photoError = nil
        let listingID = listing.id
        let owner = AuthStore.shared.userID
        let revision = AuthStore.shared.syncSessionRevision
        let workspace = WorkspaceContext.selectedOrgID
        let dest = EnhancedPhoto.directory(for: listingID).appendingPathComponent("exterior.jpg")
        let ok = await AIImagePrep.writeJPEG(image, to: dest, maxDimension: 2560, quality: 0.9)
        isSavingPhoto = false
        guard AuthStore.shared.userID == owner, AuthStore.shared.syncSessionRevision == revision,
              WorkspaceContext.selectedOrgID == workspace else {
            return "Your account or workspace changed. Reopen this home's aerial intro before saving again."
        }
        guard ok else {
            photoError = "Couldn't save this photo. Free some space and try again."
            return photoError
        }
        ImageThumbnails.invalidate(dest)
        model.setExteriorPhoto(FileStore.relativePath(for: dest), for: listingID)
        exteriorURL = dest
        exteriorVersion = UUID()
        Haptics.success()
        return nil
    }

    // MARK: - Generate (submit → poll → download; fal URLs expire, so download now)

    private func generate() {
        guard LaunchFeatureAvailability.canGenerateAerial,
              phase != .generating, !listing.isSample, !isSavingPhoto else { return }
        connection.run { generateWithSession() }
    }

    private func generateWithSession() {
        guard LaunchFeatureAvailability.canGenerateAerial,
              phase != .generating, !listing.isSample, !isSavingPhoto else { return }
        failure = nil
        statusText = hasPhoto ? "Preparing your photo…" : "Submitting…"
        phase = .generating
        Haptics.selection()

        let api = model.api                     // snapshot on the main actor
        let listingID = listing.id
        let photoURL = exteriorURL
        let spaceTypeRaw = space.rawValue
        let trimmedRegion = region.trimmingCharacters(in: .whitespacesAndNewlines)
        let hint = styleHint.trimmingCharacters(in: .whitespacesAndNewlines)
        let timeOfDayRaw = timeOfDay.rawValue
        let motionRaw = motion.rawValue
        let secs = seconds
        let aspectValue = aspect
        let tapKey = UUID().uuidString          // one idempotency key per user tap

        workTask = Task {
            do {
                var request = AerialRequest(spaceType: spaceTypeRaw)
                request.region = trimmedRegion.isEmpty ? nil : String(trimmedRegion.prefix(80))
                request.timeOfDay = timeOfDayRaw
                request.motion = motionRaw
                request.style = hint.isEmpty ? nil : String(hint.prefix(200))
                request.seconds = secs
                request.aspect = aspectValue
                if let photoURL {
                    guard let b64 = await AIImagePrep.jpegBase64(at: photoURL, maxDimension: 1280, quality: 0.85) else {
                        throw AIImagePrep.error("Couldn't read the exterior photo. Choose it again.")
                    }
                    request.imageJPEGBase64 = b64
                    request.mime = "image/jpeg"
                }
                // COMPLIANCE (W2-C4): anchor the clip so its simulated camera
                // movement is disclosed on the tour and logged for the broker.
                // Best effort — a missing anchor never blocks the generation.
                request.listingServerID = await model.serverListingIDForCompliance(listingID)
                request.label = "Aerial intro"
                try Task.checkCancellation()
                await MainActor.run { statusText = "Submitting…" }

                let job = try await api.aiVideoAerial(request, idempotencyKey: tapKey)
                let pending = PendingAerialJob(job: job, listingID: listingID, submittedAt: Date(),
                                               grounded: job.grounded ?? (photoURL != nil),
                                               aspect: aspectValue)
                pending.save()
                let sentence = job.disclosureText
                await MainActor.run {
                    grounded = pending.grounded
                    if let sentence, !sentence.isEmpty { disclosureText = sentence }
                    statusText = "Generating aerial…"
                }
                try await pollAndStore(pending, api: api)
            } catch is CancellationError {
                // Closed mid-generate — the persisted job resumes on the next open.
            } catch {
                await MainActor.run {
                    Analytics.trackAIFailure("aerial", step: "generate", error: error)
                    phase = clipURL != nil ? .result : .form
                    failure = AIFailure(error, title: "That one didn't generate")
                }
            }
        }
    }

    /// Pick up a job that was submitted earlier (the sheet was closed or the app
    /// switched away while it generated).
    private func resume(_ pending: PendingAerialJob) {
        guard phase != .generating else { return }
        connection.run { resumeWithSession(pending) }
    }

    private func resumeWithSession(_ pending: PendingAerialJob) {
        guard phase != .generating else { return }
        phase = .generating
        statusText = "Picking up your aerial…"
        grounded = pending.grounded
        if let sentence = pending.job.disclosureText, !sentence.isEmpty { disclosureText = sentence }
        failure = nil
        let api = model.api
        workTask = Task {
            do {
                try await pollAndStore(pending, api: api)
            } catch is CancellationError {
                // Closed again — still resumable while the record is fresh.
            } catch {
                await MainActor.run {
                    phase = clipURL != nil ? .result : .form
                    failure = AIFailure(error, title: "Couldn't finish the earlier aerial")
                }
            }
        }
    }

    /// Poll every 6 s, download the finished mp4 into Documents/Aerials, attach it
    /// to the listing, then delete the previous clip — only after the new one is
    /// safely on disk. A definitive failure clears the pending record; a
    /// cancellation leaves it for the next open.
    private func pollAndStore(_ pending: PendingAerialJob, api: APIClient) async throws {
        let deadline = max(pending.submittedAt.addingTimeInterval(15 * 60),
                           Date().addingTimeInterval(3 * 60))
        var remoteURL: URL?
        while remoteURL == nil {
            guard Date() < deadline else {
                PendingAerialJob.clear(for: pending.listingID)
                throw AIImagePrep.error("The aerial took too long. Please generate it again.")
            }
            try await Task.sleep(nanoseconds: 6_000_000_000)
            switch try await api.aiVideoStatus(pending.job) {
            case .processing(let queuePosition):
                let label = queuePosition.flatMap { q in
                    q > 0 ? "Generating aerial… (#\(q) in queue)" : nil
                } ?? "Generating aerial…"
                await MainActor.run { statusText = label }
            case .completed(let videoURL):
                remoteURL = videoURL
            case .failed(let message):
                PendingAerialJob.clear(for: pending.listingID)
                throw AIImagePrep.error(message)
            }
        }
        guard let remoteURL else {
            PendingAerialJob.clear(for: pending.listingID)
            throw AIImagePrep.error("The AI didn't return a video. Try again.")
        }

        await MainActor.run { statusText = "Downloading your aerial…" }
        let (tmp, resp) = try await URLSession.shared.download(from: remoteURL)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            PendingAerialJob.clear(for: pending.listingID)
            throw AIImagePrep.error("Couldn't download the finished aerial (HTTP \(http.statusCode)). Try again.")
        }
        let dir = FileStore.aerialsDir
        let dest = dir.appendingPathComponent(
            "\(pending.listingID.uuidString)-\(Int(Date().timeIntervalSince1970)).mp4")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        PendingAerialJob.clear(for: pending.listingID)
        // Store the required sentence next to the clip so a later open prints
        // the server's exact wording, not a fallback.
        let storedDisclosure = pending.job.disclosureText
        AerialMeta(grounded: pending.grounded, aspect: pending.aspect, disclosure: storedDisclosure)
            .save(for: pending.listingID)

        await MainActor.run {
            let previous = model.listings.first(where: { $0.id == pending.listingID })?.aerialURL
            model.setAerial(relPath: FileStore.relativePath(for: dest), generatedAt: Date(),
                            for: pending.listingID)
            if let previous, previous.standardizedFileURL.path != dest.standardizedFileURL.path {
                try? FileManager.default.removeItem(at: previous)   // only AFTER the new clip landed
            }
            player?.pause()
            clipURL = dest
            grounded = pending.grounded
            if let storedDisclosure, !storedDisclosure.isEmpty { disclosureText = storedDisclosure }
            resultPortrait = pending.aspect == "9:16"
            // A new file — drop the previous clip's measurement so the box falls
            // back to the aspect this job asked for until the new one is read.
            measuredAspect = nil
            player = AVPlayer(url: dest)
            savedToPhotos = false
            saveError = nil
            failure = nil
            phase = .result
            Haptics.success()
            Analytics.track("aerial_made", ["ok": "true"])
        }
    }

    private func saveToPhotos(_ url: URL) {
        guard !isSaving else { return }
        isSaving = true
        saveError = nil
        Task {
            do {
                try await PhotosLibrarySaver.saveVideo(at: url)
                await MainActor.run {
                    isSaving = false
                    savedToPhotos = true
                    Haptics.success()
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    saveError = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Parked reel clips (already generated, already BILLED)

/// How many finished reels a listing keeps on this phone.
///
/// Was 3. A reel costs a round of AI clips, and until the listing screen grew its
/// FILES section a finished reel was reachable only four navigation levels deep
/// inside Reel Studio, behind a sign-in gate — so the fourth reel quietly deleted
/// the first one before the agent had ever laid eyes on it. That is the whole
/// complaint from the 4,000 sq ft field test: "they all cost credits, I can't be
/// losing them." Ten is more than any single listing produced in that test and is
/// a season's worth of posts for one home; at ~10–40 MB a reel the worst case is a
/// few hundred MB for a listing the agent can delete outright, and every one of the
/// ten is now visible on the listing screen, so nothing is pruned before it has
/// been surfaced.
///
/// FILE SCOPE on purpose: `pruneReels` is called from inside a detached (and
/// therefore non-isolated) task, and a `static let` on `ReelStudioView` — a
/// `View`, and so `@MainActor` — would be main-actor isolated at that call site.
/// Same defect class the Mac build caught in `GearStore.normalizedASIN`.
private let reelsKeptPerListing = 10

/// The shortest and longest a PLANNED shot may run on screen, in seconds. Every
/// photo clip is generated at a fixed 5 s, so a shot list may tighten a detail to
/// 3 s or hold a hero to 8 s and no further — below 3 s a shot is a flash frame,
/// past 8 s a 5 s clip is slowed enough to judder, and the bound keeps the reel's
/// total close to the length its script was written to fit.
///
/// FILE SCOPE, for the same reason `reelsKeptPerListing` is: both are read from
/// `nonisolated` statics on `ReelStudioView`, and a `static let` on a `View` — and
/// so on a `@MainActor` type — would be main-actor isolated at those call sites.
/// That is the exact defect the Mac build caught in `GearStore.normalizedASIN`.
private let clipTrimSeconds: Double = 3
private let clipHoldSeconds: Double = 8

/// The exact token the `ai-copy` routes write where the property should be named
/// (COPY-ASSIST-CONTRACT §5). FILE SCOPE for the same isolation reason as the two
/// constants above — it is read from a `nonisolated` static.
private let addressToken = "{address}"

/// Reel clips that were already generated — and already CHARGED — when a reel run
/// stopped before the stitch. The mp4s are moved out of the run's temp directory
/// into `Documents/reels/<listingID>-parked/` and recorded under
/// `reel.clips.<listingID>`, so reopening Reel Studio can finish the reel from work
/// the agent has already paid for.
///
/// THE DEFECT (the 4,000 sq ft field test). Reel Studio's Close button was
/// unguarded: Close → `dismiss()` → `.onDisappear` → `workTask?.cancel()` → the
/// build's `catch`, which ran `removeItem(at: tmpDir)` BEFORE it checked for
/// cancellation and then `return`ed past every piece of error UI. Six clips could
/// be generated, billed, and silently erased with nothing on screen to say so.
/// Clips are the expensive half of a reel; the stitch is free and on-device.
///
/// Same shape as `PendingAerialJob` — Codable, one UserDefaults key per listing,
/// `load`/`save`/`clear`, resumed from `onAppear`, guarded Close — with two
/// deliberate differences. It holds FILES rather than a remote job handle, so it
/// stores Documents-RELATIVE paths (the container base moves between launches).
/// And it has NO `maxAge`: a fal job handle really is stale after two hours, but a
/// finished mp4 the agent paid for never is, and expiring one on a timer would be
/// this same bug in a slower form. It is cleared when the clips are stitched into a
/// reel, when the agent explicitly discards them, or when the listing is deleted
/// (`FileStore.deleteListingFiles` sweeps `reels/<id>-*`, folders included).
struct PendingReelClips: Codable {
    var listingID: UUID
    var savedAt: Date
    /// Documents-relative paths, in the order the clips were generated.
    var relPaths: [String]

    static func key(_ id: UUID) -> String { "reel.clips.\(id.uuidString)" }

    /// `Documents/reels/<listingID>-parked/`. Inside `reels/` deliberately: the
    /// `<listingID>-` prefix means `FileStore.deleteListingFiles` already sweeps it,
    /// and `ReelStudioView.reelFiles` already ignores it (that glob keeps only
    /// `.mp4` FILES, and this is a directory).
    static func directory(for id: UUID) -> URL {
        FileStore.documents
            .appendingPathComponent("reels", isDirectory: true)
            .appendingPathComponent("\(id.uuidString)-parked", isDirectory: true)
    }

    /// Absolute URLs of the parked clips that are still really on disk, in order.
    var clipURLs: [URL] {
        relPaths
            .map { FileStore.url(fromRelativePath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Reading never deletes clip files. An unreadable authoritative manifest
    /// must not revive old preferences or turn a missing record into new work.
    static func readRecord(for id: UUID) throws -> PendingReelClips? {
        do {
            let target = directory(for: id).appendingPathComponent("manifest.json")
            let data = FileManager.default.fileExists(atPath: target.path)
                ? try Data(contentsOf: target) : UserDefaults.standard.data(forKey: key(id))
            guard let data else { return nil }
            let parked = try JSONDecoder().decode(Self.self, from: data)
            guard parked.listingID == id else { throw CocoaError(.fileReadCorruptFile) }
            return parked
        } catch {
            throw AIImagePrep.error("Saved clip history couldn't be read. Your clip files have been kept. Check this phone's storage and reopen Reel Studio before retrying.")
        }
    }

    static func load(for id: UUID) -> PendingReelClips? {
        guard let parked = try? readRecord(for: id), !parked.clipURLs.isEmpty else { return nil }
        return parked
    }

    func save() { try? saveDurably() }

    func saveDurably() throws {
        _ = try Self.readRecord(for: listingID)
        let data = try JSONEncoder().encode(self)
        let target = Self.directory(for: listingID).appendingPathComponent("manifest.json")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
        guard try Data(contentsOf: target) == data else { throw AIImagePrep.error("Couldn't save the retained clips. Free some space and retry the saved request.") }
        // Old records remain readable, but this verified file is authoritative.
        UserDefaults.standard.removeObject(forKey: Self.key(listingID))
    }

    /// Retire only this run's copies after its finished reel is written.
    /// Earlier paid clips and unrelated files remain available for finishing.
    static func retire(_ clips: [URL], for id: UUID) {
        guard let parked = load(for: id) else { return }
        let chosen = Set(clips.map { $0.standardizedFileURL })
        let dir = directory(for: id).standardizedFileURL
        let removed = parked.relPaths.filter {
            let url = FileStore.url(fromRelativePath: $0).standardizedFileURL
            return chosen.contains(url) && url.deletingLastPathComponent().standardizedFileURL == dir
        }
        let remaining = parked.relPaths.filter { !removed.contains($0) }
        if remaining.isEmpty {
            UserDefaults.standard.removeObject(forKey: key(id))
            try? FileManager.default.removeItem(at: directory(for: id).appendingPathComponent("manifest.json"))
        }
        else { PendingReelClips(listingID: id, savedAt: parked.savedAt, relPaths: remaining).save() }
        for path in removed { try? FileManager.default.removeItem(at: FileStore.url(fromRelativePath: path)) }
    }

    /// Forget the record AND delete the parked mp4s. Only ever called once the
    /// clips are inside a finished reel, or when the agent said to discard them.
    static func clear(for id: UUID) {
        UserDefaults.standard.removeObject(forKey: key(id))
        try? FileManager.default.removeItem(at: directory(for: id))
    }
}

/// Standalone Animate has its own journal: it must never adopt a Make Video
/// receipt. A lost submission or quality reply remains uncertain, not a new tap.
enum PhotoAnimationRecovery {
    struct Context: Codable, Equatable, Sendable {
        let actor: String
        let library: UUID?
        let listing: UUID
        let serverListing: UUID?
        let photoVersion: String
        let sourceFile: String
        let sourceSHA256: String
        let spaceType: String
    }
    struct RefusedOperation: Codable, Sendable {
        let operationID: UUID
        let status: Int
    }
    struct Entry: Codable, Sendable {
        let schema: Int
        let context: Context
        let operationID: UUID
        let sourceJPEG: Data
        let jpegSHA256: String
        var dispatched = false
        var job: AIVideoJob?
        var clipSHA256: String?
        var qualityDispatched = false
        var qualityPassed: Bool?
        var message: String?
        var completed = false
        var refusedBeforeAcceptance: Bool? = nil
        var refusedStatus: Int? = nil
        var refusedOperations: [RefusedOperation]? = nil
    }
    struct Summary: Sendable {
        let context: Context
        let operationID: UUID
        let dispatched: Bool
        let job: AIVideoJob?
    }
    enum Failure: Error, LocalizedError {
        case unavailable, submissionUnknown, qualityUnknown, waiting, failed(String)
        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "The saved video request could not be verified. Your photo and request have been kept. Contact support before starting another video."
            case .submissionUnknown:
                return "The video submission is saved, but its reply was not received. No new generation will be started. Contact support to recover this saved request."
            case .qualityUnknown:
                return "This video's quality check is saved but could not be confirmed. It is held safely; checking again will not purchase another generation or quality check."
            case .waiting:
                return "This video is still saved. Return to this photo and check its video again; no new generation will be started."
            case .failed(let message): return message
            }
        }
    }
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func key(_ context: Context) -> String {
        // The source hash is checked inside the record, not used to evade an
        // uncertain operation by changing the same version's bytes.
        digest(try! JSONEncoder().encode([context.actor, context.library?.uuidString ?? "local",
                                          context.listing.uuidString, context.photoVersion]))
    }
    private static func folder(_ directory: URL) -> URL {
        directory.appendingPathComponent(".photo-animation-requests", isDirectory: true)
    }
    static func file(_ context: Context, directory: URL) -> URL {
        folder(directory).appendingPathComponent(key(context) + ".json")
    }
    static func load(_ context: Context, directory: URL) throws -> Entry? {
        let url = file(context, directory: directory)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, (1...13_000_000).contains(size) else { throw Failure.unavailable }
        let entry = try JSONDecoder().decode(Entry.self, from: Data(contentsOf: url))
        guard entry.schema == 1, entry.context == context,
              !context.actor.isEmpty, !context.photoVersion.isEmpty,
              context.sourceFile == URL(fileURLWithPath: context.sourceFile).lastPathComponent,
              context.sourceSHA256.count == 64, (1...9_000_000).contains(entry.sourceJPEG.count),
              digest(entry.sourceJPEG) == entry.jpegSHA256,
              entry.job == nil || valid(entry.job!),
              !entry.completed || (entry.qualityPassed == true && entry.clipSHA256 != nil) else { throw Failure.unavailable }
        return entry
    }
    private static func valid(_ job: AIVideoJob) -> Bool {
        job.kind == "reel" && !job.requestId.isEmpty && job.requestId.utf8.count <= 200
            && [job.statusUrl, job.responseUrl].allSatisfy {
                guard let url = URL(string: $0) else { return false }
                return url.scheme == "https" && url.host != nil && url.user == nil && url.password == nil
            }
    }
    private static func save(_ entry: Entry, directory: URL) throws {
        let target = file(entry.context, directory: directory)
        let data = try JSONEncoder().encode(entry)
        guard data.count <= 13_000_000 else { throw Failure.unavailable }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: target, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: target.path)
        #endif
        var excluded = target.deletingLastPathComponent()
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        guard try Data(contentsOf: target) == data else { throw Failure.unavailable }
    }
    static func pending(directory: URL, actor: String, library: UUID?, listing: UUID) -> [Summary] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder(directory), includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { url in
            guard url.pathExtension == "json", let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey]),
                  values.isSymbolicLink != true, let size = values.fileSize, (1...13_000_000).contains(size),
                  let bytes = try? Data(contentsOf: url), let entry = try? JSONDecoder().decode(Entry.self, from: bytes),
                  entry.context.actor == actor, entry.context.library == library, entry.context.listing == listing,
                  !entry.completed, url.resolvingSymlinksInPath().path == file(entry.context, directory: directory).resolvingSymlinksInPath().path,
                  let verified = try? load(entry.context, directory: directory) else { return nil }
            return Summary(context: verified.context, operationID: verified.operationID, dispatched: verified.dispatched, job: verified.job)
        }.sorted { $0.operationID.uuidString < $1.operationID.uuidString }
    }
    private static func isDefinitiveRefusal(_ error: Error) -> Bool {
        guard let api = error as? APIError, let status = api.status else { return false }
        return (400...499).contains(status) && status != 408 && status != 409
    }
    @MainActor private static var active: Set<String> = []

    /// Every provider boundary is injected so the production persistence and
    /// race decisions execute in focused tests without making paid requests.
    @MainActor static func run(context: Context, directory: URL,
        prepare: () async throws -> Data,
        requireCurrent: @escaping () throws -> Void,
        submit: (Data, String) async throws -> AIVideoJob,
        poll: (AIVideoJob) async throws -> AIVideoStatus,
        download: (URL) async throws -> URL,
        judge: (AIVideoJob, Data, URL, () throws -> Void) async throws -> DriftVerdict,
        lookup: ((UUID, UUID) async throws -> AIVideoJob?)? = nil,
        validateSource: () throws -> Void = {},
        now: () -> Date = Date.init,
        pause: () async throws -> Void = { try await Task.sleep(nanoseconds: 6_000_000_000) }) async throws -> URL {
        try requireCurrent()
        let identity = file(context, directory: directory).path
        guard active.insert(identity).inserted else { throw Failure.waiting }
        defer { active.remove(identity) }
        var entry: Entry
        let saved = try load(context, directory: directory)
        if let saved { entry = saved }
        else {
            let jpeg = try await prepare()
            try requireCurrent()
            guard (1...9_000_000).contains(jpeg.count) else { throw Failure.unavailable }
            entry = Entry(schema: 1, context: context, operationID: UUID(), sourceJPEG: jpeg, jpegSHA256: digest(jpeg))
            try save(entry, directory: directory) // Exact input and operation BEFORE paid dispatch.
        }
        if entry.refusedBeforeAcceptance == true {
            guard !entry.dispatched, entry.job == nil, !entry.qualityDispatched,
                  let status = entry.refusedStatus, (400...499).contains(status), status != 408, status != 409 else { throw Failure.unavailable }
            var history = entry.refusedOperations ?? []
            history.append(RefusedOperation(operationID: entry.operationID, status: status))
            let next = Entry(schema: 1, context: context, operationID: UUID(), sourceJPEG: entry.sourceJPEG, jpegSHA256: entry.jpegSHA256)
            entry = next; entry.refusedOperations = history
            try save(entry, directory: directory) // Only this new explicit user check retires the refused key.
        }
        let candidate = directory.appendingPathComponent(".animation-\(entry.operationID.uuidString).mp4")
        let finished = directory.appendingPathComponent("clip-\(entry.operationID.uuidString).mp4")
        if entry.completed {
            guard let expected = entry.clipSHA256, let bytes = try? Data(contentsOf: finished), digest(bytes) == expected else { throw Failure.unavailable }
            try requireCurrent(); return finished
        }
        if let message = entry.message { throw Failure.failed(message) }
        if saved != nil, entry.dispatched, entry.job == nil, let listing = context.serverListing, let lookup {
            try requireCurrent()
            if let recovered = try await lookup(entry.operationID, listing) {
                guard valid(recovered), entry.job == nil || entry.job!.requestId == recovered.requestId,
                      entry.job?.provenanceID == nil || entry.job?.provenanceID == recovered.provenanceID else { throw Failure.unavailable }
                entry.job = recovered; try save(entry, directory: directory)
            }
            try requireCurrent()
        }
        if entry.job == nil {
            guard !entry.dispatched else { throw Failure.submissionUnknown }
            try requireCurrent()
            entry.dispatched = true; try save(entry, directory: directory)
            let job: AIVideoJob
            do { job = try await submit(entry.sourceJPEG, entry.operationID.uuidString) }
            catch is CancellationError { throw CancellationError() }
            catch {
                if Self.isDefinitiveRefusal(error), let api = error as? APIError {
                    entry.dispatched = false; entry.refusedBeforeAcceptance = true; entry.refusedStatus = api.status
                    try save(entry, directory: directory)
                    throw error // No automatic retry and no server financial-state mutation.
                }
                throw Failure.submissionUnknown
            }
            guard valid(job) else { throw Failure.submissionUnknown }
            entry.job = job
            try save(entry, directory: directory) // Retain202 even if actor/cancellation changed while awaiting it.
        }
        try requireCurrent()
        guard let job = entry.job else { throw Failure.submissionUnknown }
        var clip: URL?
        if let expected = entry.clipSHA256 {
            for url in [candidate, finished] where FileManager.default.fileExists(atPath: url.path) {
                guard digest(try Data(contentsOf: url)) == expected else { throw Failure.unavailable }
                clip = url; break
            }
        }
        if clip == nil {
            let deadline = now().addingTimeInterval(10 * 60)
            while clip == nil {
                try requireCurrent()
                guard now() < deadline else { throw Failure.waiting }
                let status = try await poll(job)
                try requireCurrent()
                switch status {
                case .processing:
                    try await pause()
                case .failed:
                    entry.message = "The service could not finish this saved video. Your photo and paid request are retained; no new generation was started."
                    try save(entry, directory: directory); throw Failure.failed(entry.message!)
                case .completed(let url):
                    let temporary = try await download(url)
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    try requireCurrent()
                    let bytes = try Data(contentsOf: temporary, options: .mappedIfSafe)
                    guard !bytes.isEmpty, bytes.count <= 256 * 1024 * 1024 else { throw Failure.unavailable }
                    let downloadedSHA = digest(bytes)
                    guard entry.clipSHA256 == nil || entry.clipSHA256 == downloadedSHA else { throw Failure.unavailable }
                    try bytes.write(to: candidate, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: candidate.path)
                    #if os(iOS)
                    try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: candidate.path)
                    #endif
                    entry.clipSHA256 = downloadedSHA; try save(entry, directory: directory)
                    clip = candidate
                }
            }
        }
        guard let clip else { throw Failure.waiting }
        if entry.qualityPassed == nil {
            guard !entry.qualityDispatched else { throw Failure.qualityUnknown }
            try requireCurrent()
            let verdict = try await judge(job, entry.sourceJPEG, clip, {
                try requireCurrent()
                entry.qualityDispatched = true; try save(entry, directory: directory)
            })
            guard entry.qualityDispatched || !verdict.mayUse else { throw Failure.unavailable }
            entry.qualityPassed = verdict.mayUse
            if !verdict.mayUse {
                entry.message = "This saved video is held by its quality review. Your photo is unchanged. No new generation or quality check will be started."
            }
            try save(entry, directory: directory) // Exact verdict is durable before a context-dependent UI update.
        }
        try requireCurrent()
        guard entry.qualityPassed == true else { throw Failure.failed(entry.message ?? Failure.qualityUnknown.localizedDescription) }
        try validateSource()
        if clip != finished {
            guard !FileManager.default.fileExists(atPath: finished.path) else { throw Failure.unavailable }
            try FileManager.default.moveItem(at: clip, to: finished)
        }
        guard digest(try Data(contentsOf: finished)) == entry.clipSHA256 else { throw Failure.unavailable }
        entry.completed = true; try save(entry, directory: directory)
        try requireCurrent(); return finished
    }
}

/// One confirmed provider receipt. A connection or download failure can resume
/// this request without submitting or charging for a second generation.
struct PendingReelRequest: Codable, Sendable {
    struct Context: Codable, Sendable, Equatable {
        let listingID: UUID
        let serverListingID: UUID?
        let owner: String
        let workspace: UUID?
    }
    let context: Context
    let photoNumber: Int
    let job: AIVideoJob
    var operationID: String? = nil
    var inputDigest: String? = nil
    var submissionUnconfirmed: Bool? = nil
    var sourceJPEGBase64: String? = nil
    var sourceSpaceType: String? = nil
    var qualityAttempt: Int? = nil
    var framing: String? = nil
    var outputAspect: String? = nil
    var sourceAssetID: String? = nil
    var photoProvenanceID: String? = nil
    static func key(_ context: Context) -> String {
        "reel.request.\(context.listingID).\(context.owner).\(context.workspace?.uuidString ?? "local")"
    }
    static func file(_ context: Context) -> URL {
        let hash = SHA256.hash(data: Data(key(context).utf8)).map { String(format: "%02x", $0) }.joined()
        return FileStore.documents.appendingPathComponent("reel-requests", isDirectory: true).appendingPathComponent(hash + ".json")
    }
    static func load(_ context: Context) -> PendingReelRequest? {
        let target = file(context)
        let data = AdoptionOwnedIdentity.pathIsOccupied(target)
            ? (try? Data(contentsOf: target)) : UserDefaults.standard.data(forKey: key(context))
        guard let data,
              let request = try? JSONDecoder().decode(Self.self, from: data), request.context == context,
              request.job.kind == "reel", (1...VideoSelectionCapacity.maximumPhotos).contains(request.photoNumber),
              request.framing == nil || request.framing == "preserve_photo",
              request.outputAspect == nil || ["9:16", "16:9"].contains(request.outputAspect!) else { return nil }
        return request
    }
    static func exists(_ context: Context) -> Bool {
        if AdoptionOwnedIdentity.pathIsOccupied(file(context)) || UserDefaults.standard.object(forKey: key(context)) != nil { return true }
        guard context.workspace == nil, let owner = UUID(uuidString: context.owner) else { return false }
        do {
            return !(try AdoptionOwnedIdentity.unselectedReviewFiles(owner: owner, listingID: context.listingID,
                documents: FileStore.documents, defaults: UserDefaults.standard)).isEmpty
        } catch { return true }
    }
    static func hasUnreadableAdoptionMetadata(_ context: Context) -> Bool {
        guard context.workspace == nil, let owner = UUID(uuidString: context.owner) else { return false }
        do {
            _ = try AdoptionOwnedIdentity.unselectedReviewFiles(owner: owner, listingID: context.listingID,
                documents: FileStore.documents, defaults: UserDefaults.standard)
            return false
        } catch { return true }
    }
    static func forget(_ context: Context) {
        try? FileManager.default.removeItem(at: file(context))
        UserDefaults.standard.removeObject(forKey: key(context))
        if context.workspace == nil, let owner = UUID(uuidString: context.owner) {
            AdoptionOwnedIdentity.forgetUnselectedReviews(owner: owner, listingID: context.listingID,
                documents: FileStore.documents, defaults: UserDefaults.standard)
        }
    }
    func save() throws {
        let data = try JSONEncoder().encode(self)
        let target = Self.file(context)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
        guard try Data(contentsOf: target) == data else { throw AIImagePrep.error("Couldn't save the video request. Free some space and try again.") }
        UserDefaults.standard.removeObject(forKey: Self.key(context))
    }
    func clear() {
        // A late completion cannot remove a different receipt.
        guard Self.load(context)?.job.requestId == job.requestId else { return }
        try? FileManager.default.removeItem(at: Self.file(context))
        UserDefaults.standard.removeObject(forKey: Self.key(context))
    }
}

/// New runs keep their exact prepared photos and ordered progress. This is local
/// owned recovery metadata, never an authorization or a substitute for server QC.
/// Legacy single-photo receipts continue to recover without inventing a batch.
struct PendingReelBatch: Codable, Sendable {
    struct Shot: Codable, Sendable {
        let photoID: String; let order: Int; let motion: String?; let room: String?
        let onScreenText: String?; let seconds: Double?; let voiceLine: String?
        init(_ shot: AIShot) {
            photoID = shot.photoID; order = shot.order; motion = shot.motion; room = shot.room
            onScreenText = shot.onScreenText; seconds = shot.seconds; voiceLine = shot.voiceLine
        }
        var value: AIShot { AIShot(photoID: photoID, order: order, motion: motion, room: room,
            onScreenText: onScreenText, seconds: seconds, voiceLine: voiceLine) }
    }
    struct Photo: Codable, Sendable {
        let id: String; let jpegBase64: String; let shot: Shot?
        var sourceAssetID: String? = nil
        var photoProvenanceID: String? = nil
    }
    let context: PendingReelRequest.Context
    let id: UUID
    let photos: [Photo]
    let motion: String
    let aspect: String
    let spaceType: String
    var completedPaths: [String]
    var completedSources: [ListingVideoSource]? = nil
    var framing: String? = nil
    var scenePlanVersion: Int? = nil
    var scenePlanningNotice: String? = nil
    var automaticOrder: Bool? = nil
    var usedPlanningFallback: Bool? = nil
    static func file(_ context: PendingReelRequest.Context) -> URL {
        FileStore.documents.appendingPathComponent("reels/\(context.listingID.uuidString)-batch", isDirectory: true)
            .appendingPathComponent(PendingReelRequest.file(context).lastPathComponent)
    }
    static func exists(_ context: PendingReelRequest.Context) -> Bool { AdoptionOwnedIdentity.pathIsOccupied(file(context)) }
    static func load(_ context: PendingReelRequest.Context) throws -> Self? {
        guard exists(context) else { return nil }
        let target = file(context)
        guard let fileBytes = try target.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              fileBytes > 0, fileBytes <= VideoSelectionCapacity.maximumRecipeBytes else {
            throw AIImagePrep.error("The saved video recipe is too large to open safely. Its photos and clips have been kept.")
        }
        let data = try Data(contentsOf: target)
        guard data.count <= VideoSelectionCapacity.maximumRecipeBytes else { throw CocoaError(.fileReadCorruptFile) }
        let batch = try JSONDecoder().decode(Self.self, from: data)
        guard batch.context == context, (1...VideoSelectionCapacity.maximumPhotos).contains(batch.photos.count),
              Set(batch.photos.map(\.id)).count == batch.photos.count,
              batch.completedPaths.count <= batch.photos.count,
              batch.completedSources == nil || batch.completedSources?.count == batch.completedPaths.count,
              Set(batch.completedPaths).count == batch.completedPaths.count,
              ["9:16", "16:9"].contains(batch.aspect),
              batch.framing == nil || batch.framing == "preserve_photo",
              batch.scenePlanVersion == nil || (batch.scenePlanVersion == 1 && batch.photos.enumerated().allSatisfy({ index, photo in
                  photo.shot?.photoID == photo.id && photo.shot?.order == index + 1 && photo.shot?.seconds == 5 &&
                  ["fly_through", "push_in", "side_glide", "pull_back"].contains(photo.shot?.motion ?? "")
              })),
              batch.photos.reduce(0, { $0 + $1.jpegBase64.utf8.count }) <= VideoSelectionCapacity.maximumPreparedBase64Bytes,
              batch.photos.allSatisfy({ !$0.id.isEmpty && $0.jpegBase64.utf8.count <= VideoSelectionCapacity.maximumPhotoBase64Bytes && !(Data(base64Encoded: $0.jpegBase64)?.isEmpty ?? true) }),
              batch.completedPaths.allSatisfy({ path in
                  !path.hasPrefix("/") && !path.split(separator: "/").contains("..") &&
                  FileStore.url(fromRelativePath: path).deletingLastPathComponent().standardizedFileURL == PendingReelClips.directory(for: context.listingID).standardizedFileURL &&
                  ((try? FileStore.url(fromRelativePath: path).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0
              }) else { throw AIImagePrep.error("The saved reel batch could not be verified. Your saved requests and clips have been kept.") }
        return batch
    }
    func save() throws {
        let bytes = try JSONEncoder().encode(self), target = Self.file(context)
        guard bytes.count <= VideoSelectionCapacity.maximumRecipeBytes else {
            throw AIImagePrep.error("This video recipe is too large to save safely. Choose fewer photos or smaller source copies; no photos were removed.")
        }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: target, options: .atomic)
        guard try Data(contentsOf: target) == bytes else { throw AIImagePrep.error("Couldn't save reel progress. Your request has been kept.") }
    }
    func clear() {
        guard (try? Self.load(context))?.id == id else { return }
        try? FileManager.default.removeItem(at: Self.file(context))
    }
}

private enum ReelRecoveryChoice { case saferRetry, originalPhoto }

// MARK: - Reel Studio (multi-photo → AI motion clips → one stitched social video)
// Pick up to 100 listing photos; each becomes a 5 s motion clip via
// POST /ai-video/reel-clip (sequential submit → poll → download), then the
// clips are stitched ON-DEVICE with AVFoundation into a single 9:16 or 16:9
// mp4 saved to Documents/reels/. `extraClipURLs` (e.g. the listing's aerial
// intro) are ready-made clips that lead the reel — no AI call for those.
// Inline here per the new-file-not-in-target rule.

/// Only a confirmed property-drift verdict requests the bounded safer move.
/// Network, decode, unavailable QC, consent and admission failures are not this.
private struct ReelQualityRefusal: Error, LocalizedError {
    let verdict: DriftVerdict
    var errorDescription: String? { verdict.refusal }
    var mayRetry: Bool { verdict.status == .fail && verdict.action == "retry" }
}

/// A reel stops at the first failed photo. Keep the position and a safe reason
/// instead of reducing every error to a count and spending on the next photo.
struct ReelClipIssue: Identifiable {
    let photoNumber: Int
    let failure: AIFailure
    var id: Int { photoNumber }

    init(photoNumber: Int, error: Error) {
        self.photoNumber = photoNumber
        failure = Self.failure(for: error, title: "Photo \(photoNumber) couldn't become a clip")
    }

    static func failure(for error: Error, title: String) -> AIFailure {
        let original = AIFailure(error, title: title)
        let message: String
        if let refusal = error as? ReelQualityRefusal, refusal.mayRetry {
            message = "The AI changed the property, so this clip was held. Choose one safer retry or keep your selected photo as a still shot."
        } else if let api = error as? APIError, (api.status ?? 0) >= 500 || api.code == "upstream" || api.code == "internal" {
            message = "The video service is unavailable right now, so this clip wasn't made. If it keeps happening, contact support from Settings → Legal & support."
        } else if AIFailure.isOffline(error) {
            message = "The connection stopped. Check your connection before making more clips."
        } else {
            let raw = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            // A submit, poll or download failure does not establish whether the
            // provider charged. Never repeat a raw payload or promise a refund.
            let machine = raw.contains("{\"") || raw.contains("[{") || raw.contains("Traceback")
                || raw.range(of: #"HTTP \d{3}"#, options: .regularExpression) != nil
            message = machine ? "The video service couldn't process this photo. Review the photo and try again later." : original.message
        }
        return AIFailure(original, title: title, message: message)
    }
}

private enum VideoPhotoSourceChoice: String, CaseIterable, Identifiable {
    case finished = "Finished edits", originals = "Originals", all = "All saved"
    var id: String { rawValue }
    func includes(_ version: PhotoVersionHistory.Version?) -> Bool {
        switch self {
        case .finished: return version?.effects.isEmpty == false
        case .originals: return version?.isRetainedOriginalSource == true
        case .all: return true
        }
    }
}

/// Browsing filters never replace a picked version or change its position.
private enum VideoPhotoPickerPresentation {
    static func initialChoice(_ current: VideoPhotoSourceChoice, explicitlyChosen: Bool,
                              finishedCount: Int, originalCount: Int) -> VideoPhotoSourceChoice {
        !explicitlyChosen && current == .finished && finishedCount == 0 && originalCount > 0 ? .originals : current
    }

    static func selectionSummary(_ count: Int) -> String {
        count == 0 ? "0 photos" : count == 1 ? "1 photo selected" : "\(count) photos selected"
    }

    enum EmptyState: String {
        case savedError, noPhotos, noFinished, noOriginals, noMatching
        var title: String {
            switch self {
            case .savedError: return "Review your saved photos"
            case .noPhotos: return "Add your property photos"
            case .noFinished: return "No finished edits yet"
            case .noOriginals: return "No originals here"
            case .noMatching: return "No matching photos"
            }
        }
        var message: String? {
            switch self {
            case .noFinished: return "Choose Originals above, or review saved edits in Photos."
            case .noOriginals: return "Try another filter or review saved versions in Photos."
            case .noMatching: return "Try another shape. Your selection is kept."
            default: return nil
            }
        }
        var action: String {
            self == .noMatching ? "Show all shapes" : self == .noPhotos ? "Add photos" : "Open Photos"
        }
    }

    static func emptyState(hasError: Bool, allCount: Int, sourceCount: Int, visibleCount: Int,
                           choice: VideoPhotoSourceChoice) -> EmptyState? {
        if hasError { return .savedError }
        if allCount == 0 { return .noPhotos }
        if sourceCount == 0 { return choice == .finished ? .noFinished : .noOriginals }
        return visibleCount == 0 ? .noMatching : nil
    }
}

/// Local diagrams explain the choices without sending a photo to any model.
private struct VideoSetupDemo: View {
    let kind: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var moved = false
    private var title: String { ["Choose the finished version", "Fit the screen", "Move through each photo", "Review before sharing"][kind] }
    private var caption: String { ["Decluttered and staged results keep their own badges. Tap the exact version you want.", "Wide for listings. Tall for social. Preview a crop before you create.", "A gentle glide animates one photo; separate rooms are not a connected 3D tour.", "Check fixed features and every staged result. Originals stay unchanged."][kind] }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                if kind == 0 {
                    Image(systemName: "photo").font(.system(size: 28)).foregroundStyle(Theme.inkDim)
                    Image(systemName: "arrow.right").foregroundStyle(Theme.inkDim)
                    Label("Finished", systemImage: "checkmark.circle.fill").font(.rpCaption.weight(.semibold)).foregroundStyle(Theme.good)
                } else if kind == 1 {
                    RoundedRectangle(cornerRadius: 6).stroke(Theme.accent, lineWidth: 2).frame(width: 90, height: 51)
                        .overlay(Image(systemName: "house.fill").foregroundStyle(Theme.accent))
                    RoundedRectangle(cornerRadius: 6).stroke(Theme.accent, lineWidth: 2).frame(width: 36, height: 64)
                        .overlay(Image(systemName: "house.fill").foregroundStyle(Theme.accent))
                } else if kind == 2 {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8).fill(Theme.accentSoft).frame(width: 130, height: 64)
                        Image(systemName: "house.fill").font(.system(size: 28)).foregroundStyle(Theme.accent)
                            .offset(x: reduceMotion ? 0 : moved ? 9 : -9)
                        Image(systemName: "arrow.left.and.right").offset(y: 26).foregroundStyle(Theme.accent)
                    }
                } else {
                    Image(systemName: "photo.on.rectangle").font(.system(size: 30)).foregroundStyle(Theme.accent)
                    Image(systemName: "checkmark.shield.fill").font(.system(size: 30)).foregroundStyle(Theme.good)
                }
                Spacer(minLength: 0)
            }.frame(minHeight: 72).accessibilityHidden(true)
            Text(title).font(.rpBody.weight(.semibold)).foregroundStyle(Theme.ink)
            Text(caption).font(.rpCaption).foregroundStyle(Theme.inkDim).fixedSize(horizontal: false, vertical: true)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.fillSubtle, in: RoundedRectangle(cornerRadius: 12))
            .onAppear { if !reduceMotion { withAnimation(.easeInOut(duration: 1.2)) { moved = true } } }
            .onChange(of: reduceMotion) { value in if value { moved = false } }
    }
}

/// A local diagram changes only when a choice is made. It never loops or
/// implies that separate still photos form a connected 3D camera path.
private struct ReelMotionCue: View {
    let move: ReelCameraMove?
    let selected: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var direction: String {
        switch move { case .flyThrough: return "arrow.up.right"; case .pushIn: return "arrow.down.right.and.arrow.up.left"
        case .sideGlide: return "arrow.left.and.right"; case .pullBack: return "arrow.up.left.and.arrow.down.right"
        case nil: return "sparkles" }
    }
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.accentSoft)
            Image(systemName: "house.fill").font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .scaleEffect(selected && !reduceMotion && move == .pushIn ? 1.14 : selected && !reduceMotion && move == .pullBack ? 0.86 : 1)
                .offset(x: selected && !reduceMotion && move == .sideGlide ? 3 : 0,
                        y: selected && !reduceMotion && move == .flyThrough ? -2 : 0)
            Image(systemName: direction).font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.accent).padding(3)
                .background(Theme.card, in: Circle()).offset(x: 3, y: 3)
        }
        .frame(width: 30, height: 30)
        .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.75), value: selected)
        .accessibilityHidden(true)
    }
}

struct ReelStudioView: View {
    @ObservedObject private var work: ReelWorkJob
    private let reviewingExistingJob: Bool
    @EnvironmentObject var model: AppModel
    @ObservedObject private var auth = AuthStore.shared
    @ObservedObject private var processorConsent = PropertyVideoProcessorConsent.shared
    @State private var preparingProcessor = false
    @State private var preparedProcessorContext: PropertyVideoJobContext?
    @State private var preparedProcessorPermission: PropertyVideoProcessorSnapshot?
    @State private var preparedSessionRevision: UInt64?
    @State private var preparedBaseRevision: UInt64?
    @State private var preparedProcessorRevision: UInt64?
    @Environment(\.dismiss) private var dismiss
    let listing: Listing
    let photos: [EnhancedPhoto]
    @State private var refreshedPhotos: [EnhancedPhoto]?
    @State private var savedPhotoError: String?
    @State private var showReelPhotos = false
    @State private var sourceChoice: VideoPhotoSourceChoice = .finished
    @State private var sourceChoiceExplicitlyChosen = false
    @State private var videoPhotoVersions: [String: PhotoVersionHistory.Version] = [:]
    @State private var sourceSelectionNotice: String?
    @State private var pendingPhotoEdits = 0
    @State private var pendingPhotoNote: String?
    @ObservedObject private var photoWork = PhotoWorkQueue.shared
    private enum SetupStep: Int, Hashable {
        case photos, format, review
        var navigationTitle: String {
            switch self { case .photos: return "Photos"; case .format: return "Look"; case .review: return "Review" }
        }
    }
    @State private var setupPath: [SetupStep] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var videoDynamicTypeSize
    private var setupStep: SetupStep {
        get { setupPath.last ?? .photos }
        nonmutating set {
            switch newValue {
            case .photos: setupPath = []
            case .format: setupPath = [.format]
            case .review: setupPath = [.format, .review]
            }
        }
    }
    private var sourcePhotos: [EnhancedPhoto] { reelPhotos.filter { sourceChoice.includes(videoPhotoVersions[$0.id]) } }
    private var reelPhotos: [EnhancedPhoto] { refreshedPhotos ?? photos }
    @State private var photoOrientationFilter: PhotoOrientation?
    @State private var photoOrientations: [PhotoGeometryInput: PhotoOrientation] = [:]
    private var photoGeometryInputs: [PhotoGeometryInput] {
        reelPhotos.map { PhotoGeometryInput(id: $0.id, url: $0.enhancedURL) }
    }
    private func photoOrientation(_ photo: EnhancedPhoto) -> PhotoOrientation {
        photoOrientations[PhotoGeometryInput(id: photo.id, url: photo.enhancedURL)] ?? .unknown
    }
    private var filteredReelPhotos: [EnhancedPhoto] {
        PhotoOrientation.filtered(sourcePhotos, by: photoOrientationFilter, orientation: photoOrientation)
    }
    /// Finished clips to put in front of the photo clips (the aerial intro).
    var extraClipURLs: [URL] = []

    private typealias Phase = ReelWorkJob.Phase

    /// Which voiceover the agent is building, if any. `.off` (default) makes the
    /// reel with no voiceover, exactly as before this feature existed.
    private enum VoiceMode: Hashable { case off, myVoice, aiVoice }

    /// How an AI-written script should sound. The raw values ARE the contract's
    /// `tone` values — one place, so a rename can't silently send a word the
    /// server doesn't know.
    ///
    /// Kept deliberately unobtrusive in the UI: `defaultTone(for:)` already
    /// picks the one that suits the space type, so nobody has to touch it, and
    /// nobody is asked a question before they get their script.
    private enum ScriptTone: String, CaseIterable, Hashable {
        case warm, punchy, luxury

        var label: String {
            switch self {
            case .warm:   return "Warm"
            case .punchy: return "Punchy"
            case .luxury: return "Luxury"
            }
        }
    }

    /// Text burned onto the exported reel. Plain Sendable strings — resolved on
    /// the main actor in generate(), rendered as CALayers inside the composer.
    ///
    /// The type itself moved to `Render/ReelComposer.swift` when the stitch did;
    /// this alias keeps every call site in this screen reading the way it always
    /// has. A `typealias` carries no isolation of its own, so naming it from
    /// inside a `@MainActor` `View` costs a non-isolated caller nothing.
    typealias ReelCaptions = ReelTitleCard

    private var phase: Phase { get { work.phase } nonmutating set { work.phase = newValue } }
    @State private var selected: [String] = []      // grid follows upload order; selections keep the agent's tap order
    @State private var selectedExtras: [URL] = []   // extra clips still switched on
    @State private var seededExtras = false
    @State private var acceptedOpening: PropertyVideoAcceptedOpening?
    @State private var includeAcceptedOpening = false
    @State private var openingCatalogueNote: String?
    @State private var availableOpenings: [AerialOpeningCatalogue.Entry] = []
    @State private var showAcceptedOpeningPicker = false
    @State private var openingContext: PropertyVideoJobContext?
    @State private var openingSessionRevision: UInt64?
    @State private var resolvedOpeningChoice: AerialOpeningStore.Selection?
    private var currentOpeningSelectionContext: PropertyVideoJobContext? {
        guard !listing.isSample, let current = model.listings.first(where: { $0.id == listing.id }),
              current.cloudUnavailable != true, let server = current.serverID, current.serverOrgID != nil,
              let actor = auth.userID.flatMap(UUID.init(uuidString:)), let org = WorkspaceContext.selectedOrgID else { return nil }
        return PropertyVideoJobContext(localListingID: listing.id, listingID: server, actorID: actor, orgID: org)
    }
    private var currentOpeningChoice: AerialOpeningStore.Selection? {
        guard let context = currentOpeningSelectionContext else { return nil }
        return AerialOpeningStore.selection(context, aspect: portrait ? "9:16" : "16:9")
    }
    private var openingSelectionIsResolved: Bool {
        guard let choice = currentOpeningChoice, choice.included else { return !includeAcceptedOpening }
        guard photoMotion, includeAcceptedOpening, resolvedOpeningChoice == choice,
              let context = currentOpeningSelectionContext, openingContext == context,
              openingSessionRevision == auth.syncSessionRevision, let opening = acceptedOpening,
              opening.reference == choice.reference, opening.scope == choice.scope,
              opening.aspect == choice.aspect,
              opening.scope.orgID == model.listings.first(where: { $0.id == listing.id })?.serverOrgID else { return false }
        return true
    }
    private var chosenOpening: PropertyVideoAcceptedOpening? {
        photoMotion && includeAcceptedOpening && acceptedOpening?.aspect == (portrait ? "9:16" : "16:9") ? acceptedOpening : nil
    }
    private var selectedTimelineFrames: Int { selectedPhotoFrames + (chosenOpening?.reference.visibleFrames ?? 0) }

    @State private var videoPurpose: VideoAspectChoice?
    /// Existing snapshots, saved drafts and recovery records keep their exact
    /// portrait contract. Purpose owns it now; legacy nil remains social video.
    private var portrait: Bool {
        get { videoPurpose?.portrait ?? true }
        nonmutating set { videoPurpose = VideoAspectChoice(portrait: newValue) }
    }
    @State private var captionsOn = false           // Social title/mark, visible in Format & motion.
    /// Picture labels remain visible in Format & motion. A fresh video
    /// starts with clean imagery and no unexplained text overlays.
    @State private var bigCaptionsOn = false
    @State private var bigCaptionStyle: ReelComposer.ShotCaptionStyle = .lowerThird
    /// Defaults to hard cuts, and the copy under the picker says why.
    @State private var reelTransition: ReelComposer.Transition = .cut
    @State private var motionPrompt = "" // Legacy draft field; never dispatched by preset UI.
    @State private var cameraMove: ReelCameraMove? = nil // Automatic per-photo motion by default.
    @State private var photoMotion = true
    @State private var photoMotionProfile = PhotoMotionContract.Profile.current
    @State private var photoMotionDirection = PhotoMotionContract.Direction.pushIn
    @State private var photoMotionFrames: [String: Int] = [:]
    @State private var photoMotionDigests: [PhotoGeometryInput: String] = [:]
    @State private var photoMotionTimingRestoreGeneration = UUID()
    @State private var photoMotionTimingRestorePending = false
    private func photoMotionKey(_ id: String) -> String? {
        guard let photo = reelPhotos.first(where: { $0.id == id }), let version = photo.savedVersion,
              let digest = photoMotionDigests[PhotoGeometryInput(id: id, url: photo.enhancedURL)] else { return nil }
        return PhotoMotionContract.timingKey(photoID: id, provenanceID: version.provenanceID?.lowercased(), sha256: digest)
    }
    private func restorePhotoMotionTimings(_ request: PropertyVideoJobRequest) {
        guard request.isPhotoMotion, request.isValid else { return }
        photoMotionFrames = Dictionary(uniqueKeysWithValues: request.sources.compactMap { source in
            guard let photo = reelPhotos.first(where: { $0.id == source.photoID }), let version = photo.savedVersion,
                  let key = PhotoMotionContract.restoredTimingKey(source, photoID: photo.id, localVersionID: version.id,
                    historicalProvenanceID: version.provenanceID) else { return nil }
            return (key, source.visibleFrames ?? 48)
        })
        restoreOriginalPhotoMotionTimings(request)
    }
    private func restoreOriginalPhotoMotionTimings(_ request: PropertyVideoJobRequest) {
        let generation = UUID(); photoMotionTimingRestoreGeneration = generation
        photoMotionTimingRestorePending = false
        guard let context = currentOpeningSelectionContext,
              request.listingID == context.listingID, request.expectedOrgID == context.orgID,
              let physical = model.listings.first(where: { $0.id == listing.id })?.serverOrgID else { return }
        let revision = auth.syncSessionRevision
        photoMotionTimingRestorePending = true
        Task { @MainActor in
            defer { if photoMotionTimingRestoreGeneration == generation { photoMotionTimingRestorePending = false } }
            @MainActor func check() throws {
                try Task.checkCancellation()
                guard photoMotionTimingRestoreGeneration == generation, context.hasCurrentIdentity,
                      currentOpeningSelectionContext == context, auth.syncSessionRevision == revision,
                      model.listings.first(where: { $0.id == listing.id })?.serverOrgID == physical else {
                    throw PropertyVideoJobStore.Failure.identityChanged
                }
            }
            for source in request.sources {
                do {
                    try check()
                    guard let photo = reelPhotos.first(where: { $0.id == source.photoID }), let version = photo.savedVersion else { continue }
                    let raw = photo.enhancedURL
                    let original = version.originalFile.map { raw.deletingLastPathComponent().appendingPathComponent($0) } ?? raw
                    if let key = try await PropertyVideoOriginalMaster.restoredTimingKey(source, version: version,
                        imageURL: raw, originalURL: original, context: context, physicalOrgID: physical, requireCurrent: check) {
                        try check()
                        guard photo.savedVersion == version, photoMotionFrames[key] == nil else { continue }
                        photoMotionFrames[key] = source.visibleFrames ?? 48
                    }
                } catch { /* An unverified copy never supplies a different source's timing. */ }
            }
        }
    }
    private func photoMotionFrameCount(_ id: String) -> Int { photoMotionKey(id).flatMap { photoMotionFrames[$0] } ?? 48 }
    private var selectedPhotoFrames: Int { selected.reduce(0) { $0 + photoMotionFrameCount($1) } }
    private var selectedPhotoMotionInputs: [PhotoGeometryInput] { selected.compactMap { id in reelPhotos.first(where: { $0.id == id }).map { PhotoGeometryInput(id: id, url: $0.enhancedURL) } } }
    @State private var automaticOrder = false
    @State private var showVideoAdvanced = false
    @State private var scenePlanningNotice: String?
    @State private var musicSelection: VideoMusicSelection? = nil
    @StateObject private var musicPreview = VideoMusicPreviewController()
    @State private var framingPreviewPhoto: EnhancedPhoto?
    @State private var allowOriginalPhotoFallback = true
    @State private var showVideoHelp = false
    @State private var pendingHelpPreview: EnhancedPhoto?
    @State private var checkingFraming = false
    @State private var showFramingReview = false
    @State private var framingAssessments: [VideoPhotoFramingAssessment] = []
    @State private var pendingFramingKey: String?
    @State private var acknowledgedFramingKey: String?
    private var completedClips: Int { get { work.completedClips } nonmutating set { work.completedClips = newValue } }
    private var originalPhotoMotionShots: Int { get { work.originalPhotoMotionShots } nonmutating set { work.originalPhotoMotionShots = newValue } }
    private var totalClips: Int { get { work.totalClips } nonmutating set { work.totalClips = newValue } }
    private var clipIssues: [ReelClipIssue] { get { work.clipIssues } nonmutating set { work.clipIssues = newValue } }
    private var failedClips: Int { clipIssues.count }
    private var statusText: String { get { work.statusText } nonmutating set { work.statusText = newValue } }
    private var reelURL: URL? { get { work.reelURL } nonmutating set { work.reelURL = newValue } }
    @State private var measuredReelAspect: CGFloat?
    private var player: AVPlayer? { get { work.player } nonmutating set { work.setPlaybackPlayer(newValue) } }
    @State private var savedToPhotos = false
    @State private var isSaving = false
    @State private var saveError: String?
    private var failure: AIFailure? { get { work.failure } nonmutating set { work.failure = newValue } }
    @StateObject private var connection = FeatureSessionAction()
    private var workTask: Task<Void, Never>? { work.task }
    /// The newest reel already on disk for this listing (F-A-23). Reels used to
    /// be write-only: the file survived in Documents/reels but the studio always
    /// reopened on an empty setup form, so the last one was unreachable.
    private var lastReel: URL? { get { work.lastReel } nonmutating set { work.lastReel = newValue } }
    /// Clips from an earlier run of THIS listing's reel that were generated and
    /// billed but never stitched (the 4,000 sq ft field test). Loaded on open,
    /// exactly like `AerialIntroSheet` resumes a `PendingAerialJob`.
    private var parkedClips: PendingReelClips? { get { work.parkedClips } nonmutating set { work.parkedClips = newValue } }
    private var pendingRequest: PendingReelRequest? { get { work.pendingRequest } nonmutating set { work.pendingRequest = newValue } }
    private var pendingBatch: PendingReelBatch? { get { work.pendingBatch } nonmutating set { work.pendingBatch = newValue } }
    private var unreadableBatch: Bool { get { work.unreadableBatch } nonmutating set { work.unreadableBatch = newValue } }
    private var recoveredRetryRequestID: String? { get { work.recoveredRetryRequestID } nonmutating set { work.recoveredRetryRequestID = newValue } }
    private var unreadablePendingContext: PendingReelRequest.Context? { get { work.unreadablePendingContext } nonmutating set { work.unreadablePendingContext = newValue } }
    private var reelOwner: String? { work.scope.owner }
    @State private var showDiscardParkedConfirm = false
    @State private var showDiscardPendingConfirm = false

    // MARK: Voiceover step state (optional — see docs/VOICEOVER-CONTRACT.md)
    //
    // The whole step is opt-in: `voiceMode == .off` (the default) means no
    // voiceover and the reel generates exactly as it did before. A finished
    // `voiceover` survives a mode switch (so toggling Off/My voice doesn't throw
    // away a recording); generate() reads it only when the mode isn't .off.
    @StateObject private var recorder = VoiceRecorder()
    @State private var voiceMode: VoiceMode = .off
    @State private var voiceover: Voiceover?
    @State private var wordCaptionsOn = true          // maps to CaptionStyle.enabled
    @State private var voPlayer: AVPlayer?            // playback of the take, not the reel
    @State private var requestingVoicePermission = false
    @State private var voicePermissionID: UUID?
    @State private var isTranscribing = false
    @State private var voiceError: String?            // fatal step error (mic denied, etc.)
    @State private var voiceNote: String?             // soft note (e.g. captions unavailable)
    /// Set when the mic was granted but Speech Recognition was NOT — recording
    /// still runs, transcription is skipped, captions are off.
    @State private var speechDenied = false
    // AI-voice sub-state
    @State private var aiScript = ""
    @State private var aiVoices: [AIVoice] = []
    @State private var selectedVoiceID = ""
    @State private var loadingVoices = false
    @State private var ttsInFlight = false            // one TTS call per tap (money)
    // "Write my script" sub-state.
    @State private var scriptInFlight = false         // one script call per tap
    @State private var showScriptReplaceConfirm = false
    /// How the script should sound. Seeded ONCE in `onAppear` from
    /// `defaultTone(for:)` so the default follows the space type without this
    /// view needing an `init`, and never touched again — a tone the agent
    /// picked survives every mode switch and every re-appearance.
    @State private var tone: ScriptTone = .warm
    @State private var seededTone = false
    @State private var nativeSetupRevision = 0
    @State private var nativeSetupBusy = false
    @State private var nativeSetupNotice: String?
    @State private var nativeSetupError: String?

    init(listing: Listing, photos: [EnhancedPhoto], extraClipURLs: [URL] = [], reviewingJob: ReelWorkJob? = nil) {
        self.listing = listing; self.photos = photos; self.extraClipURLs = extraClipURLs
        let restored = reviewingJob ?? ReelWorkQueue.shared.job(for: listing)
        self.work = restored
        self._photoMotion = State(initialValue: restored.serverJob?.request.isPhotoMotion ?? (!listing.isSample && restored.configuration == nil && restored.phase == .setup))
        self._photoMotionProfile = State(initialValue: restored.serverJob?.request.photoMotionProfile == .opening ? .current : (restored.serverJob?.request.photoMotionProfile ?? .current))
        self._photoMotionDirection = State(initialValue: restored.serverJob?.request.sources.first.flatMap { PhotoMotionContract.Direction(rawValue: $0.motion) } ?? .pushIn)
        self.reviewingExistingJob = reviewingJob != nil
    }

    private var space: SpaceType { listing.isSample ? SpaceType.current : listing.spaceType }
    /// The screen photos are added on — same words as its title bar.
    private var photosScreenName: String { "AI Photo Studio" }
    private var totalSelected: Int { selectedExtras.count + selected.count }
    /// A pending narration operation must settle before its audio is frozen into
    /// a video. A settled error is not a requirement to buy or record another take.
    private var narrationPreparationMessage: String? {
        if requestingVoicePermission { return "Waiting for microphone permission…" }
        if recorder.isRecording { return "Stop recording before creating" }
        if isTranscribing { return "Finishing your narration…" }
        if scriptInFlight { return "Writing your script…" }
        if ttsInFlight { return "Making your voice…" }
        return nil
    }
    private var canGenerate: Bool { openingSelectionIsResolved && !photoMotionTimingRestorePending && (!photoMotion || (!listing.isSample && selectedExtras.isEmpty && reelTransition == .cut && !bigCaptionsOn && selected.allSatisfy { photoMotionKey($0) != nil })) && narrationPreparationMessage == nil && (work.serverJob == nil || work.serverJob?.reply?.isTerminal == true) && VideoSelectionCapacity.canCreate(photoCount: selected.count, totalCount: totalSelected) && pendingRequest == nil && unreadablePendingContext == nil && pendingBatch == nil && !unreadableBatch }
    /// The app-owned job continues when this sheet is dismissed. Only the
    /// explicit Cancel action or a captured permission change stops it.
    private var isWorking: Bool { work.running || work.isServerRendering || phase == .generating || phase == .stitching }

    /// Title + which home this reel is for. iOS 16 has no `navigationSubtitle`,
    /// so the two lines are a principal toolbar item.
    private var reelTitleBar: some View {
        VStack(spacing: 1) {
            Text("Make a video")
                .font(.rpBody.weight(.semibold))
                .foregroundStyle(Theme.ink)
            Text(reelSubtitle)
                .font(.caption2)
                .foregroundStyle(Theme.inkDim)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private var reelSubtitle: String {
        let address = listing.address.trimmingCharacters(in: .whitespacesAndNewlines)
        return address.isEmpty ? "This \(space.spaceNoun)" : address
    }

    private let selectColumns = [GridItem(.flexible(), spacing: 8),
                                 GridItem(.flexible(), spacing: 8),
                                 GridItem(.flexible(), spacing: 8)]

    var body: some View {
        NavigationStack(path: $setupPath) {
            reelStageScreen(.photos)
                .navigationDestination(for: SetupStep.self) { step in reelStageScreen(step) }
        }
        .sessionConnectionNotice(isActive: connection.isWaiting, onCancel: { connection.cancel() })
        .interactiveDismissDisabled(connection.isWaiting)
        .onAppear {
            refreshVideoPhotos()
            work.isPresented = true
            if !seededExtras {
                selectedExtras = [] // Saved aerials stay available, but new videos start with the chosen photos only.
                seededExtras = true
            }
            // The tone that suits this trade, picked once. Guarded like
            // `seededExtras` above: onAppear can fire again, and it must not
            // undo a choice the agent made.
            if !seededTone {
                tone = Self.defaultTone(for: space)
                seededTone = true
            }
            if !reviewingExistingJob { lastReel = Self.newestReel(for: listing.id) }
            if aiScript.isEmpty, let script = CloudVoiceStore.script(listing.id) { aiScript = script }
            if voiceover == nil, let saved = CloudVoiceStore.voice(listing.id) {
                voiceover = saved
                voiceNote = "Saved narration is available under Voice & music."
            }
            // Pick up clips a previous run generated and was charged for but
            // never stitched — the reel equivalent of resuming a pending aerial.
            if !reviewingExistingJob, !listing.isSample { parkedClips = PendingReelClips.load(for: listing.id) }
            if !reviewingExistingJob {
                reloadPendingRequest()
                restoreVideoPurposeForSavedWork()
                restoreServerVideoJob()
            } else if let saved = work.serverJob {
                videoPurpose = saved.request.purpose == "listing" ? .listing : .socialMedia
            }
            if let reelURL, player == nil { player = AVPlayer(url: reelURL) }
        }
        .task(id: (portrait ? "9:16" : "16:9") + (work.serverJob == nil ? ":draft" : ":saved")) { await refreshAcceptedOpening() }
        .sheet(isPresented: $showAcceptedOpeningPicker) {
            if let context = openingContext {
                AerialOpeningAcceptedPicker(entries: availableOpenings, context: context, requireCurrent: {
                    guard context.hasCurrentIdentity, auth.syncSessionRevision == openingSessionRevision, phase == .setup,
                          let live = model.listings.first(where: { $0.id == listing.id }), live.serverID == context.listingID,
                          live.cloudUnavailable != true, (portrait ? "9:16" : "16:9") == (availableOpenings.first?.opening.aspect ?? "") else { throw PropertyVideoJobStore.Failure.identityChanged }
                }) { entry, _ in
                    do {
                        try AerialOpeningStore.select(entry.opening, included: true, context: context)
                        acceptedOpening = entry.opening; includeAcceptedOpening = true
                        resolvedOpeningChoice = AerialOpeningStore.selection(context, aspect: entry.opening.aspect)
                    } catch { openingCatalogueNote = error.localizedDescription }
                }
            }
        }
        .onReceive(photoWork.$job) { job in
            if let job, job.listingID == listing.id, !job.running, phase == .setup { refreshVideoPhotos() }
        }
        .onChange(of: work.serverJob?.request) { request in
            guard let request else { return }
            photoMotion = request.isPhotoMotion
            if let profile = request.photoMotionProfile { photoMotionProfile = profile == .opening ? .current : profile }
            if request.isPhotoMotion, let direction = request.sources.first.flatMap({ PhotoMotionContract.Direction(rawValue: $0.motion) }) { photoMotionDirection = direction }
            if request.isPhotoMotion {
                restorePhotoMotionTimings(request)
            }
        }
        .onChange(of: setupStep) { _ in musicPreview.stop() }
        .onChange(of: showVideoAdvanced) { expanded in if !expanded { musicPreview.stop() } }
        .onChange(of: musicSelection) { selection in musicPreview.selectionChanged(to: selection) }
        .onChange(of: voiceMode) { mode in
            musicPreview.stop()
            // Leaving My voice mid-take drops the mic/session; a finished
            // voiceover is kept. Entering AI voice seeds the script from any
            // recording transcript and loads the voice catalogue once.
            if mode != .myVoice { voicePermissionID = nil; requestingVoicePermission = false }
            if mode != .myVoice, recorder.isRecording { recorder.cancel() }
            if mode == .aiVoice {
                if aiScript.isEmpty, let t = voiceover?.transcript, !t.isEmpty { aiScript = t }
                loadVoices()
            }
        }
        .onDisappear {
            // Execution belongs to the app queue. Leaving a sheet stops only
            // its playback, microphone and unsent reconnect waiter.
            voicePermissionID = nil; requestingVoicePermission = false
            connection.cancel()
            work.isPresented = false
            player?.pause(); player = nil; voPlayer?.pause(); musicPreview.stop()
            if recorder.isRecording { recorder.cancel() }
        }
        .onChange(of: auth.userID) { owner in
            if reelOwner != owner { ReelWorkQueue.shared.reconcileIdentity(); dismiss() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .rendpropWorkspaceChanged)) { _ in
            ReelWorkQueue.shared.reconcileIdentity(); dismiss()
        }
        .confirmationDialog("Discard these clips?", isPresented: $showDiscardParkedConfirm,
                            titleVisibility: .visible) {
            Button("Discard clips", role: .destructive) { discardParkedClips() }
            Button("Keep them", role: .cancel) {}
        } message: {
            Text("This deletes saved video progress and finished clips. Remote requests are kept. Making the deleted clips again costs another round of AI.")
        }
        .confirmationDialog("Forget the saved request?", isPresented: $showDiscardPendingConfirm, titleVisibility: .visible) {
            Button("Forget request", role: .destructive) {
                if let context = pendingRequest?.context ?? unreadablePendingContext { PendingReelRequest.forget(context) }
                reloadPendingRequest()
            }
            Button("Keep request", role: .cancel) {}
        } message: {
            Text("This does not cancel the remote job or refund it. Generating this photo again may count another clip. Finished clips stay on this phone.")
        }
        // Asked ONLY when there are already words in the box. The likeliest
        // words are the transcript of a recording the agent made themselves
        // (carried over when they switch to AI voice), and nothing here is
        // allowed to throw that away without being told to.
        .confirmationDialog("Replace what's in the box?", isPresented: $showScriptReplaceConfirm,
                            titleVisibility: .visible) {
            Button("Write a new script", role: .destructive) { runScriptWriter() }
            Button("Keep what I have", role: .cancel) {}
        } message: {
            Text("There are already words in the script box. Writing a new one replaces every one of them — including anything carried over from a recording you made.")
        }
        // Guideline 5.1.2(i) — each selected photo is animated by a
        // third-party video model. Agreed once per device; declining closes
        // the studio.
        .sheet(isPresented: $showFramingReview) {
            VideoFramingReviewSheet(assessments: photoMotion ? framingAssessments : framingAssessments.filter(\.isMajorCrop), aspect: portrait ? 9.0/16.0 : 16.0/9.0, photoMotion: photoMotion, photoMotionScale: photoMotionProfile.endScale, photoMotionDirection: photoMotionDirection.rawValue, changePhotos: {
                showFramingReview = false
                setupStep = .photos
            }) {
                acknowledgedFramingKey = pendingFramingKey
                showFramingReview = false
                DispatchQueue.main.async { generate() }
            }
        }
        .sheet(isPresented: $showVideoHelp, onDismiss: {
            if let photo = pendingHelpPreview {
                pendingHelpPreview = nil
                framingPreviewPhoto = photo
            }
        }) { videoHelpSheet }
        .sheet(item: $framingPreviewPhoto) { photo in
            VideoFramingPreviewSheet(url: photo.enhancedURL, aspect: portrait ? 9.0/16.0 : 16.0/9.0, photoMotion: photoMotion, photoMotionScale: photoMotionProfile.endScale, photoMotionDirection: photoMotionDirection.rawValue)
        }
        .sheet(isPresented: $showReelPhotos, onDismiss: { refreshVideoPhotos() }) {
            NavigationStack {
                PhotoStudioView(listing: listing, entry: .photos, captureIntent: portrait ? .socialPhotos : .listingPhotos)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { showReelPhotos = false } } }
            }.environmentObject(model)
        }
        .overlay {
            if processorConsent.askingContext?.localListingID == listing.id {
                PropertyVideoProcessorPermissionCard(consent: processorConsent)
            }
        }
        .onDisappear {
            if processorConsent.askingContext?.localListingID == listing.id { processorConsent.decline() }
        }
        .aiConsentGate()
        .paywallHost(managesLifecycle: false)
    }

    private func reelStageScreen(_ step: SetupStep) -> some View {
        ScrollViewReader { scroll in
            ScrollView {
                VStack(spacing: Theme.spacing) {
                    Color.clear.frame(height: 0).id("video.setup.top")
                    switch phase {
                    case .setup: configuredSetupSection(step)
                    case .generating: generatingSection
                    case .stitching: stitchingSection
                    case .done: doneSection
                    case .failed: failedSection
                    case .paused: pausedSection
                    }
                }.padding().padding(.bottom, 24)
            }
            .safeAreaInset(edge: .bottom, spacing: 16) {
                if phase == .setup {
                    setupPrimaryAction(step)
                        .disabled(connection.isWaiting || nativeSetupBusy || preparingProcessor)
                        .padding(.horizontal, 20).padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                        .background(Theme.bg)
                }
            }
            .onChange(of: setupStep) { _ in
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    scroll.scrollTo("video.setup.top", anchor: .top)
                }
            }
        }
        .disabled(connection.isWaiting || nativeSetupBusy || preparingProcessor)
        .background(Theme.bg)
        .navigationTitle(step.navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(step == .photos || phase != .setup || isWorking || connection.isWaiting || nativeSetupBusy || preparingProcessor)
        .toolbar {
            if step == .photos || phase != .setup || isWorking || connection.isWaiting || nativeSetupBusy || preparingProcessor {
                ToolbarItem(placement: .navigationBarLeading) { videoBackButton }
            }
            ToolbarItem(placement: .principal) { reelTitleBar }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showVideoHelp = true } label: { Image(systemName: "questionmark.circle") }
                    .accessibilityLabel("How to make a video")
                    .accessibilityIdentifier("video.help")
            }
        }
    }

    private var videoBackButton: some View {
        Button { dismiss() } label: { Label("Back", systemImage: "chevron.left") }
        .accessibilityIdentifier("video.setup.back")
    }

    private func setupPrimaryAction(_ step: SetupStep) -> some View {
        Group {
            if step == .review {
                makeButton
            } else {
                Button {
                    setupStep = step == .photos ? .format : .review
                    Haptics.selection()
                } label: {
                    HStack {
                        Text(step == .photos ? "Choose the look" : "Review video")
                        Image(systemName: "arrow.right")
                    }.font(.rpBody.weight(.semibold)).frame(maxWidth: .infinity).frame(minHeight: 24)
                }
                .modifier(RendpropActionAppearance())
                .disabled(step == .photos ? selected.isEmpty : videoPurpose == nil)
                .accessibilityIdentifier("video.setup.next")
            }
        }
    }

    private var videoHelpSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    ForEach(0..<4, id: \.self) { VideoSetupDemo(kind: $0) }
                    if let id = selected.first, let photo = reelPhotos.first(where: { $0.id == id }) {
                        Button { pendingHelpPreview = photo; showVideoHelp = false } label: {
                            Label("Preview this photo", systemImage: "viewfinder")
                        }.buttonStyle(RendpropPillButtonStyle()).frame(minHeight: 44)
                    }
                    Text("1080p video. Review the crop and finished result before publishing.")
                        .font(.rpCaption).foregroundStyle(Theme.inkDim)
                }.padding()
            }
            .background(Theme.bg).navigationTitle("How it works").navigationBarTitleDisplayMode(.inline)
            .askAI(.reelStudio, listingID: listing.id)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { showVideoHelp = false } } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: Sections

    // Each native destination renders its own step while keeping selections in this studio.
    private var videoPurposeChooser: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Screen shape").font(.rpBody.weight(.semibold)).foregroundStyle(Theme.ink)
            if videoDynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 10) { formatChoices }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 148), spacing: 10)], spacing: 10) {
                    formatChoices
                }
            }
            Text(videoPurpose?.explanation ?? "Wide for a listing. Tall for social.")
                .font(.rpCaption).foregroundStyle(Theme.inkDim).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(isWorking || pendingBatch != nil || pendingRequest != nil || parkedClips != nil)
        .accessibilityIdentifier("video.purposeChooser")
    }

    private var formatChoices: some View {
        ForEach(VideoAspectChoice.allCases, id: \.rawValue) { choice in
            Button {
                withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8)) {
                    videoPurpose = choice
                }
                Haptics.selection()
            } label: {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(Theme.accent, lineWidth: 1.5)
                        .frame(width: choice.portrait ? 18 : 30, height: choice.portrait ? 30 : 18)
                        .overlay(Image(systemName: "house.fill").font(.system(size: 9)).foregroundStyle(Theme.accent))
                        .frame(width: 30, height: 32).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(choice.portrait ? "Tall" : "Wide").font(.rpBody.weight(.semibold))
                        Text(choice.aspect).font(.rpCaption).foregroundStyle(Theme.inkDim)
                    }
                    Spacer(minLength: 0)
                    if videoPurpose == choice {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                            .transition(.opacity.combined(with: .scale))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(RendpropPillButtonStyle(selected: videoPurpose == choice, compact: true, horizontalPadding: 12))
            .accessibilityLabel("\(choice.portrait ? "Tall" : "Wide"), \(choice.title), \(choice.aspect)")
            .accessibilityAddTraits(videoPurpose == choice ? .isSelected : [])
            .accessibilityIdentifier("video.purpose.\(choice.rawValue)")
        }
    }

    private func restoreVideoPurposeForSavedWork() {
        guard videoPurpose == nil else { return }
        let savedAspect = pendingBatch?.aspect ?? pendingRequest?.outputAspect ?? work.configuration?.aspect
        if savedAspect != nil || pendingRequest != nil || pendingBatch != nil || parkedClips != nil || isWorking {
            if work.serverJob?.request.isPhotoMotion != true { photoMotion = false }
            videoPurpose = VideoAspectChoice.saved(aspect: savedAspect)
        }
    }

    @ViewBuilder private func configuredSetupSection(_ step: SetupStep) -> some View {
        setupHeader(step)
        parkedClipsCard
        pendingRequestCard
        lastReelCard
        switch step {
        case .photos: stepPhotosCard
        case .format: stepFormatMotionCard
        case .review: stepMakeCard
        }
    }

    @ViewBuilder private var nativeSetupCard: some View {
        if !listing.isSample && auth.isIdentified {
            VStack(alignment: .leading, spacing: 10) {
                Label("Continue in Studio", systemImage: "icloud").font(.rpBody.weight(.semibold))
                Text(photoMotion ? "Photo motion setup transfer is not supported yet. Its accepted video job remains available from this listing." : "Keep this setup for another device. Photos stored only on this iPhone still need uploading.")
                    .font(.rpCaption).foregroundStyle(Theme.inkDim)
                if videoDynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 10) { studioSetupActions }
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) { studioSetupActions }
                        VStack(spacing: 10) { studioSetupActions }
                    }
                }
                if nativeSetupBusy { ProgressView().accessibilityLabel("Updating Studio setup") }
                if let nativeSetupNotice { Text(nativeSetupNotice).font(.rpCaption).foregroundStyle(Theme.accent) }
                if let nativeSetupError { Text(nativeSetupError).font(.rpCaption).foregroundStyle(.orange) }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading).modifier(RendpropContentSurface())
        }
    }

    private var studioSetupActions: some View {
        Group {
            Button { Task { await syncNativeSetup(save: true) } } label: {
                Label("Save setup", systemImage: "square.and.arrow.up")
                    .font(.rpCaption.weight(.semibold)).frame(maxWidth: .infinity)
            }
            Button { Task { await syncNativeSetup(save: false) } } label: {
                Label("Load setup", systemImage: "arrow.down.circle")
                    .font(.rpCaption.weight(.semibold)).frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(RendpropPillButtonStyle())
        .disabled(photoMotion || nativeSetupBusy || isWorking || ttsInFlight || scriptInFlight || recorder.isRecording)
    }

    @MainActor private func syncNativeSetup(save: Bool) async {
        guard !photoMotion else { nativeSetupError = "Photo motion setup transfer is not supported yet. Your selected photos and timing stay here."; return }
        guard !nativeSetupBusy, !isWorking, !ttsInFlight, !scriptInFlight, !recorder.isRecording,
              auth.isIdentified, let cloud = model.api as? WorkspaceSyncAPI else { return }
        nativeSetupBusy = true; nativeSetupError = nil; nativeSetupNotice = nil
        defer { nativeSetupBusy = false }
        _ = await AuthStore.validAccessToken()
        let actor = auth.userID, epoch = auth.syncSessionRevision
        do {
            var live = model.listings.first(where: { $0.id == listing.id }) ?? listing
            if live.serverID == nil { _ = try await model.ensureServerListing(live) }
            if (model.listings.first(where: { $0.id == listing.id })?.serverOrgID) == nil { await model.refreshCloudWorkspace() }
            live = model.listings.first(where: { $0.id == listing.id }) ?? listing
            guard auth.userID == actor, auth.syncSessionRevision == epoch, auth.isIdentified,
                  let sid = live.serverID, let org = live.serverOrgID, live.cloudUnavailable != true else { throw CloudSyncError.identityChanged }
            if save {
                guard let ownerID = actor.flatMap(UUID.init(uuidString:)) else { throw CloudSyncError.identityChanged }
                let selectedIDs = selected
                guard Set(reelPhotos.map(\.id)).count == reelPhotos.count else { throw CloudSyncError.invalidResponse }
                let byID = Dictionary(uniqueKeysWithValues: reelPhotos.map { ($0.id, $0) })
                var sharedPhotos: [NativeReelDraft.Photo] = []
                for (index, localID) in selectedIDs.enumerated() {
                    guard let photo = byID[localID] else { throw CloudSyncError.invalidResponse }
                    nativeSetupNotice = "Checking uploaded photo \(index + 1) of \(selectedIDs.count)…"
                    let sourceID = try await CloudPhotoReferences.shared.sourceID(fileURL: photo.enhancedURL,
                        ownerID: ownerID, orgID: org, listingID: sid)
                    guard auth.userID == actor, auth.syncSessionRevision == epoch, auth.isIdentified,
                          selected == selectedIDs else { throw CloudSyncError.identityChanged }
                    sharedPhotos.append(.init(localId: localID, sourcePhotoId: sourceID))
                }
                nativeSetupNotice = "Saving setup to your account…"
                let voiceID = voiceMode == .off ? nil : voiceover?.sharedReference?.resultID(ownerID: ownerID, listingID: sid)
                let draft = NativeReelDraft(schema: 1, kind: "native-reel-setup", portrait: portrait, titleCard: captionsOn,
                    shotCaptions: bigCaptionsOn, captionStyle: bigCaptionStyle.rawValue, transition: reelTransition.rawValue,
                    motionPrompt: motionPrompt, script: aiScript, tone: tone.rawValue, wordCaptions: wordCaptionsOn,
                    voiceMode: voiceMode == .off ? "off" : (voiceMode == .myVoice ? "myVoice" : "aiVoice"), voiceResultId: voiceID,
                    localNarration: voiceMode != .off && voiceover != nil && voiceID == nil,
                    photos: sharedPhotos,
                    localExtraClipCount: selectedExtras.count, updatedAt: ISO8601DateFormatter().string(from: Date()),
                    motionPreset: cameraMove?.rawValue, automaticOrder: automaticOrder)
                let document = try await cloud.saveCloudNativeReel(draft, listingID: sid, orgID: org, revision: nativeSetupRevision)
                guard auth.userID == actor, auth.syncSessionRevision == epoch, auth.isIdentified else { throw CloudSyncError.identityChanged }
                nativeSetupRevision = document.revision
                let localCount = sharedPhotos.filter { $0.sourcePhotoId == nil }.count
                nativeSetupNotice = localCount == 0 ? "Setup saved to Studio with your uploaded photo selections. No new media was generated."
                    : "Setup saved. \(localCount) selected photo\(localCount == 1 ? " is" : "s are") still on this iPhone; upload the photos, then save setup again."
            } else {
                let document = try await cloud.cloudNativeReel(listingID: sid, orgID: org)
                guard auth.userID == actor, auth.syncSessionRevision == epoch, auth.isIdentified else { throw CloudSyncError.identityChanged }
                guard let document else { nativeSetupRevision = 0; nativeSetupNotice = "No saved setup yet. Save this one to continue at the office."; return }
                let draft = document.payload
                let planning = draft.planningSetup
                portrait = draft.portrait; captionsOn = draft.titleCard; bigCaptionsOn = planning.pictureLabels
                bigCaptionStyle = ReelComposer.ShotCaptionStyle(rawValue: draft.captionStyle) ?? .lowerThird
                reelTransition = ReelComposer.Transition(rawValue: draft.transition) ?? .cut
                motionPrompt = ""; cameraMove = planning.motionPreset.flatMap(ReelCameraMove.init(rawValue:)); automaticOrder = planning.automaticOrder; aiScript = draft.script; tone = ScriptTone(rawValue: draft.tone) ?? .warm
                wordCaptionsOn = draft.wordCaptions
                let available = Set(reelPhotos.map(\.id))
                let photoIndex = try? PhotoVersionHistory.load(directory: EnhancedPhoto.directory(for: listing.id))
                selected = draft.photos.compactMap { photo in
                    if available.contains(photo.localId) || photoIndex?.versions[photo.localId] != nil { return photo.localId }
                    if let sid = photo.sourcePhotoId { return available.first(where: { $0.lowercased() == "cloud-\(sid.uuidString.lowercased())" }) }
                    return nil
                }
                selected = Self.selectionPreservingOrder(selected, photos: reelPhotos, index: photoIndex)
                var missing: [String] = []
                if selected.count < draft.photos.count { missing.append("Save missing photos from Cloud files, then load this setup again.") }
                selectedExtras = []
                if draft.localExtraClipCount > 0 { missing.append("Choose the extra clips saved on this iPhone.") }
                if draft.voiceMode != "off", let voiceID = draft.voiceResultId,
                   let saved = CloudVoiceStore.voice(listing.id), saved.id == voiceID {
                    voiceover = saved; voiceMode = .aiVoice
                } else {
                    voiceMode = .off
                    if draft.voiceMode != "off" { missing.append(draft.localNarration ? "The recorded narration is on its original iPhone." : "Save its narration from Cloud files.") }
                }
                nativeSetupRevision = document.revision
                nativeSetupNotice = (["Saved setup loaded."] + (planning.notice.map { [$0] } ?? []) + missing).joined(separator: " ")
            }
        } catch is CancellationError { return }
        catch {
            guard auth.userID == actor, auth.syncSessionRevision == epoch else { return }
            nativeSetupError = save ? "Setup couldn't be saved. If another device changed it, load the saved setup before saving again." : "Saved setup couldn't be loaded. Refresh when connected."
        }
    }


    private func setupHeader(_ step: SetupStep) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            stepsRail(step)
            Text(step == .photos ? "Choose your photos" : step == .format ? "Choose the look" : "Your video, ready to make")
                .font(.rpTitle).foregroundStyle(Theme.ink)
            Text(step == .photos ? VideoPhotoPickerPresentation.selectionSummary(selected.count) :
                "\(selected.count) photos · " + (photoMotion ? String(format: "%.2f seconds", Double(selectedTimelineFrames) / 24) : "About \(selected.count * 5) seconds"))
                .font(.rpBody).foregroundStyle(Theme.inkDim)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
    }


    private func stepsRail(_ step: SetupStep) -> some View {
        HStack(spacing: 10) {
            Text("\(step.rawValue + 1) of 3").font(.rpCaption.weight(.semibold)).foregroundStyle(Theme.accent)
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    Capsule().fill(index <= step.rawValue ? Theme.accent : Theme.border).frame(width: 24, height: 4)
                }
            }.accessibilityHidden(true)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: step)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(step.rawValue + 1) of 3: \(step.navigationTitle)")
    }

    private var stepFormatMotionCard: some View {
        VStack(alignment: .leading, spacing: 24) {
            videoPurposeChooser
            photoMotionModeRow
            if photoMotion { photoMotionDirectionChoices; photoMotionTimingRows } else { motionRow }
            titleCardToggle
            bigCaptionsRow
            transitionRow
            if !photoMotion {
                Toggle("Use my selected photo if AI changes the property", isOn: $allowOriginalPhotoFallback).tint(Theme.accent)
                Text("Fallback keeps the exact photo version you selected and adds restrained 2D movement. Connection, billing and uncertain-quality failures stop the job.")
                    .font(.rpCaption).foregroundStyle(Theme.inkDim)
            }
            acceptedOpeningCard
            if !extraClipURLs.isEmpty { clipsCard }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).modifier(RendpropContentSurface())
    }

    /// A numbered step heading. One per card, so nobody has to guess the order.
    private func stepTitle(_ number: Int, _ title: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("STEP \(number) · \(title)")
                .font(.rpKicker).foregroundStyle(Theme.accent)
            if !note.isEmpty {
                Text(note).font(.rpCaption).foregroundStyle(Theme.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // --- Step 1: photos ---

    private var stepPhotosCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            photoSourceFilters
            photoProcessingStatus
            if let sourceSelectionNotice { Text(sourceSelectionNotice).font(.rpCaption).foregroundStyle(Theme.warn) }
            photoPickerGrid
            if savedPhotoError == nil && !filteredReelPhotos.isEmpty {
                Button { showReelPhotos = true } label: {
                    Label("Manage photos", systemImage: "photo.on.rectangle")
                        .font(.rpCaption.weight(.semibold)).frame(maxWidth: .infinity)
                }.buttonStyle(RendpropPillButtonStyle(compact: true))
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).modifier(RendpropContentSurface())
    }

    private var photoFilterColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 8), count: videoDynamicTypeSize.isAccessibilitySize ? 1 : 2)
    }

    private var photoSourceFilters: some View {
        LazyVGrid(columns: photoFilterColumns, spacing: 8) {
            ForEach(VideoPhotoSourceChoice.allCases) { choice in
                Button {
                    sourceChoiceExplicitlyChosen = true
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { sourceChoice = choice }
                    Haptics.selection()
                } label: {
                    HStack(spacing: 6) {
                        Text(choice.rawValue).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Text("\(reelPhotos.filter { choice.includes(videoPhotoVersions[$0.id]) }.count)")
                            .monospacedDigit()
                    }.font(.rpCaption.weight(.semibold)).frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(RendpropPillButtonStyle(selected: sourceChoice == choice, compact: true, horizontalPadding: 12))
                .accessibilityAddTraits(sourceChoice == choice ? .isSelected : [])
                .accessibilityIdentifier("video.photos.versions.\(choice.id)")
            }
        }.accessibilityIdentifier("video.photos.versions")
    }

    private var photoShapeFilters: some View {
        let counts = PhotoOrientation.counts(sourcePhotos.map(photoOrientation))
        let choices = PhotoOrientation.allCases.filter { counts[$0, default: 0] > 0 || photoOrientationFilter == $0 }
        return Group {
            if choices.count > 1 || photoOrientationFilter != nil {
                LazyVGrid(columns: photoFilterColumns, spacing: 8) {
                    photoShapeButton(nil, title: "All shapes")
                    ForEach(choices, id: \.self) { choice in photoShapeButton(choice, title: choice.label) }
                }.accessibilityIdentifier("video.photos.orientation")
            }
        }
    }

    private func photoShapeButton(_ choice: PhotoOrientation?, title: String) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { photoOrientationFilter = choice }
            Haptics.selection()
        } label: {
            Text(title).font(.rpCaption.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(RendpropPillButtonStyle(selected: photoOrientationFilter == choice, compact: true, horizontalPadding: 12))
        .accessibilityAddTraits(photoOrientationFilter == choice ? .isSelected : [])
    }

    @ViewBuilder private var photoProcessingStatus: some View {
        if let job = photoWork.visibleJob, job.listingID == listing.id, job.running {
            HStack(spacing: 8) {
                ProgressView()
                Text("Processing photo \(min(max(1, job.current), job.total)) of \(job.total) · \(job.done) saved")
                    .font(.rpCaption.weight(.semibold)).foregroundStyle(Theme.ink)
            }
        } else if let pendingPhotoNote {
            Text(pendingPhotoNote).font(.rpCaption).foregroundStyle(Theme.warn)
        } else if pendingPhotoEdits > 0 {
            Text("\(pendingPhotoEdits) saved edit\(pendingPhotoEdits == 1 ? " is" : "s are") awaiting a result. Check saved edits in Photos.")
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
        }
    }

    @ViewBuilder private var acceptedOpeningCard: some View {
        if let choice = currentOpeningChoice, choice.included, !openingSelectionIsResolved {
            VStack(alignment: .leading, spacing: 12) {
                Label("Opening clip · needs attention", systemImage: "airplane.departure").font(.rpHeadline)
                Text(!photoMotion ? "Use Photo motion to start with this opening, or turn the opening off for AI camera." : "Your saved opening must be checked before creating this video. You can also continue without it.")
                    .font(.rpBody).foregroundStyle(Theme.inkDim).fixedSize(horizontal: false, vertical: true)
                Button("Check opening again") { Task { await refreshAcceptedOpening() } }
                    .buttonStyle(RendpropPillButtonStyle()).accessibilityIdentifier("video.opening.retry")
                Button("Continue without opening") { turnOffSavedOpening(choice) }
                    .buttonStyle(RendpropPillButtonStyle()).accessibilityIdentifier("video.opening.turnOff")
                if !availableOpenings.isEmpty { chooseAcceptedOpeningButton }
            }.padding(18).modifier(RendpropContentSurface())
        } else if let opening = acceptedOpening {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: Binding(get: { includeAcceptedOpening }, set: { value in
                    guard let context = openingContext, context.hasCurrentIdentity else { return }
                    do {
                        guard currentOpeningSelectionContext == context, auth.syncSessionRevision == openingSessionRevision else { throw PropertyVideoJobStore.Failure.identityChanged }
                        try AerialOpeningStore.select(opening, included: value, context: context); includeAcceptedOpening = value
                        resolvedOpeningChoice = AerialOpeningStore.selection(context, aspect: opening.aspect)
                    }
                    catch { openingCatalogueNote = error.localizedDescription }
                })) {
                    Label("Opening clip · first", systemImage: "airplane.departure")
                        .font(.rpHeadline).fixedSize(horizontal: false, vertical: true)
                }.tint(Theme.accent).accessibilityIdentifier("video.opening.included")
                if includeAcceptedOpening && !photoMotion {
                    Text("Use Photo motion to start with this opening, or turn the opening off for AI camera.")
                        .font(.rpBody).foregroundStyle(Theme.inkDim).fixedSize(horizontal: false, vertical: true)
                }
                Text(String(format: "%.2f seconds before your photos. Their order, timing and movement stay unchanged.", opening.durationS))
                    .font(.rpCaption).foregroundStyle(Theme.inkDim).fixedSize(horizontal: false, vertical: true)
                Text(opening.disclosure).font(.rpCaption).foregroundStyle(Theme.inkDim).fixedSize(horizontal: false, vertical: true)
                if !availableOpenings.isEmpty { chooseAcceptedOpeningButton }
            }.padding(18).modifier(RendpropContentSurface())
        } else if !availableOpenings.isEmpty { chooseAcceptedOpeningButton }
        if let openingCatalogueNote {
            Text(openingCatalogueNote).font(.rpCaption).foregroundStyle(Theme.inkDim).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var chooseAcceptedOpeningButton: some View {
        Button { showAcceptedOpeningPicker = true } label: {
            Label(acceptedOpening == nil ? "Choose an opening clip" : "Change opening clip", systemImage: "airplane.departure")
                .font(.rpBody.weight(.semibold)).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity)
        }.buttonStyle(RendpropPillButtonStyle()).accessibilityIdentifier("video.opening.choose")
    }
    private func turnOffSavedOpening(_ choice: AerialOpeningStore.Selection) {
        guard phase == .setup, work.serverJob == nil, let context = currentOpeningSelectionContext,
              context.hasCurrentIdentity,
              choice.scope.orgID == model.listings.first(where: { $0.id == listing.id })?.serverOrgID else { return }
        do {
            try AerialOpeningStore.turnOff(choice, context: context)
            includeAcceptedOpening = false
            resolvedOpeningChoice = AerialOpeningStore.selection(context, aspect: choice.aspect)
            openingCatalogueNote = nil
        } catch { openingCatalogueNote = error.localizedDescription }
    }
    private func refreshAcceptedOpening() async {
        guard phase == .setup, work.serverJob == nil, !listing.isSample,
              let current = model.listings.first(where: { $0.id == listing.id }), let server = current.serverID,
              let physical = current.serverOrgID, let actor = auth.userID.flatMap(UUID.init(uuidString:)), let org = WorkspaceContext.selectedOrgID else { return }
        let aspect = portrait ? "9:16" : "16:9", revision = auth.syncSessionRevision
        let context = PropertyVideoJobContext(localListingID: listing.id, listingID: server, actorID: actor, orgID: org)
        if acceptedOpening?.aspect != aspect { acceptedOpening = nil; includeAcceptedOpening = false; availableOpenings = [] }
        openingContext = context; openingSessionRevision = revision; openingCatalogueNote = nil
        let choice = AerialOpeningStore.selection(context, aspect: aspect)
        resolvedOpeningChoice = nil
        if choice?.included != true { includeAcceptedOpening = false }
        let before = acceptedOpening?.reference, includedBefore = includeAcceptedOpening
        do {
            let catalogue = try await AerialOpeningService.catalogue(context: context, physicalOrgID: physical, aspect: aspect)
            guard context.hasCurrentIdentity, auth.syncSessionRevision == revision, phase == .setup, work.serverJob == nil,
                  (portrait ? "9:16" : "16:9") == aspect,
                  let live = model.listings.first(where: { $0.id == listing.id }), live.serverID == server, live.serverOrgID == physical, live.cloudUnavailable != true else { return }
            guard AerialOpeningStore.selection(context, aspect: aspect) == choice else { return }
            availableOpenings = catalogue.accepted
            guard acceptedOpening?.reference == before, includeAcceptedOpening == includedBefore,
                  let choice, choice.scope.orgID == physical else { return }
            guard let entry = catalogue.accepted.first(where: { $0.opening.reference == choice.reference }) else {
                openingCatalogueNote = "The saved opening is unavailable. Choose another saved opening or turn it off."; return
            }
            acceptedOpening = entry.opening; includeAcceptedOpening = choice.included
            resolvedOpeningChoice = choice
        } catch {
            guard context.hasCurrentIdentity, auth.syncSessionRevision == revision, phase == .setup, work.serverJob == nil,
                  openingContext == context, (portrait ? "9:16" : "16:9") == aspect,
                  AerialOpeningStore.selection(context, aspect: aspect) == choice else { return }
            openingCatalogueNote = "Couldn't check the saved opening. Reopen this video when connected to include it. Your photos are kept."
        }
    }

    private func restoreServerVideoJob() {
        guard !listing.isSample, let current = model.listings.first(where: { $0.id == listing.id }),
              let serverID = current.serverID, let actor = AuthStore.shared.userID.flatMap(UUID.init(uuidString:)),
              let org = WorkspaceContext.selectedOrgID, let jobsAPI = model.api as? PropertyVideoJobsAPI else { return }
        let context = PropertyVideoJobContext(localListingID: listing.id, listingID: serverID, actorID: actor, orgID: org)
        PropertyVideoJobRunner.shared.restore(work: work, model: model, api: jobsAPI, context: context)
        if let saved = work.serverJob { videoPurpose = saved.request.purpose == "listing" ? .listing : .socialMedia }
    }

    private func refreshVideoPhotos() {
        do {
            refreshedPhotos = try EnhancedPhoto.loadForListing(listingID: listing.id)
            let directory = EnhancedPhoto.directory(for: listing.id)
            let index = try PhotoVersionHistory.load(directory: directory)
            videoPhotoVersions = index.versions
            refreshedPhotos = Self.videoPhotoCatalogue(refreshedPhotos ?? [], index: index, directory: directory)
            savedPhotoError = nil
            sourceChoice = VideoPhotoPickerPresentation.initialChoice(sourceChoice, explicitlyChosen: sourceChoiceExplicitlyChosen,
                finishedCount: reelPhotos.filter { VideoPhotoSourceChoice.finished.includes(videoPhotoVersions[$0.id]) }.count,
                originalCount: reelPhotos.filter { VideoPhotoSourceChoice.originals.includes(videoPhotoVersions[$0.id]) }.count)
            let previous = selected
            selected = Self.selectionPreservingOrder(selected, photos: reelPhotos, index: index)
            sourceSelectionNotice = selected == previous ? nil : "A selected version is no longer available. Review your selection; no different version was substituted."
            if let owner = auth.userID, let library = WorkspaceContext.selectedOrgID {
                do {
                    pendingPhotoEdits = try PhotoPendingEdit.saved(actor: owner, library: library, listing: listing.id, directory: directory).count
                    pendingPhotoNote = nil
                } catch {
                    pendingPhotoEdits = 0
                    pendingPhotoNote = "Saved photo requests could not be verified. Review them in Photos before starting another paid edit."
                }
            }
        } catch {
            refreshedPhotos = []; videoPhotoVersions = [:]
            savedPhotoError = "The selected photo versions need attention. Your saved photos are kept; review them in Photos before creating a video."
        }
    }

    nonisolated private static func videoPhotoCatalogue(_ published: [EnhancedPhoto], index: PhotoVersionHistory.Index,
                                                      directory: URL) -> [EnhancedPhoto] {
        let saved = index.orderedForLibrary(Array(index.versions.values)).filter {
            !index.hiddenFamilies.contains($0.familyID) && FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.imageFile).path)
        }.map { version in
            EnhancedPhoto(id: version.id, originalURL: directory.appendingPathComponent(version.reviewSourceFile(in: index)),
                          enhancedURL: directory.appendingPathComponent(version.imageFile))
        }
        var seen = Set<String>()
        return (saved + published).filter { seen.insert($0.id).inserted }
    }

    @ViewBuilder private var photoPickerGrid: some View {
        Group {
            let empty = VideoPhotoPickerPresentation.emptyState(hasError: savedPhotoError != nil, allCount: reelPhotos.count,
                sourceCount: sourcePhotos.count, visibleCount: filteredReelPhotos.count, choice: sourceChoice)
            if let empty {
                VStack(alignment: .leading, spacing: 10) {
                    Label(empty.title, systemImage: "photo.on.rectangle").font(.rpHeadline).foregroundStyle(Theme.ink)
                    if let message = savedPhotoError ?? empty.message {
                        Text(message).font(.rpCaption).foregroundStyle(Theme.inkDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button(empty.action) {
                        if empty == .noMatching { photoOrientationFilter = nil } else { showReelPhotos = true }
                    }.buttonStyle(RendpropPillButtonStyle(compact: true))
                        .accessibilityIdentifier("video.photos.empty.recovery")
                }.frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    photoShapeFilters
                    Text("Tap in the order you want.").font(.rpCaption).foregroundStyle(Theme.inkDim)
                    LazyVGrid(columns: selectColumns, spacing: 8) {
                        ForEach(filteredReelPhotos) { p in
                            VStack(alignment: .leading, spacing: 4) {
                                selectThumb(p)
                                Text(videoPhotoVersions[p.id]?.title ?? "Saved photo").font(.rpCaption.weight(.semibold)).foregroundStyle(Theme.ink)
                                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                                Text(photoOrientation(p).label).font(.rpCaption).foregroundStyle(Theme.inkDim)
                                    .accessibilityIdentifier("video.photos.orientation.\(p.id)")
                            }
                        }
                    }
                }
            }
        }
        .task(id: photoGeometryInputs) {
            let inputs = photoGeometryInputs, actor = auth.userID, revision = auth.syncSessionRevision
            let workspace = WorkspaceContext.selectedOrgID
            let values = await PhotoGeometryReader.observe(inputs)
            guard !Task.isCancelled, photoGeometryInputs == inputs, auth.userID == actor,
                  auth.syncSessionRevision == revision, WorkspaceContext.selectedOrgID == workspace else { return }
            photoOrientations = values
        }
    }

    // --- Step 3: shape + the button ---


    private var stepMakeCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            formatRow
            acceptedOpeningCard
            Label(photoMotion ? "Photo motion · \(photoMotionDirection.title) · \(photoMotionProfile.percent)%" : (cameraMove?.title ?? "Automatic motion for each photo"), systemImage: photoMotion ? "photo" : "video")
                .font(.rpBody.weight(.semibold)).foregroundStyle(Theme.ink)
            VStack(spacing: 12) {
                ForEach(Array(selected.enumerated()), id: \.element) { order, id in
                    if let photo = reelPhotos.first(where: { $0.id == id }) {
                        HStack(spacing: 14) {
                            DetailPhotoThumb(url: photo.enhancedURL, height: 104)
                                .frame(width: 84).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Photo \(order + 1)").font(.rpCaption.weight(.semibold)).foregroundStyle(Theme.accent)
                                Text(videoPhotoVersions[id]?.title ?? "Saved photo")
                                    .font(.rpBody.weight(.semibold)).foregroundStyle(Theme.ink)
                                    .fixedSize(horizontal: false, vertical: true)
                                if photoMotion {
                                    Text("\(photoMotionFrameCount(id) / 24) seconds").font(.rpBody).foregroundStyle(Theme.inkDim)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.fillSubtle, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .accessibilityElement(children: .combine)
                    }
                }
            }.accessibilityIdentifier("video.review.exactVersions")
            Button { setupStep = .photos } label: {
                videoReviewActionLabel("Change photos", systemImage: "photo.stack")
            }
            .buttonStyle(RendpropPillButtonStyle())
            .accessibilityLabel("Change photos")
            .accessibilityHint("Returns to photo selection.")
            .accessibilityIdentifier("video.review.changePhotos")
            videoAdvancedControls
            if let scenePlanningNotice { Text(scenePlanningNotice).font(.rpCaption).foregroundStyle(Theme.inkDim) }
            aiDisclosureLine
            if photoMotion {
                Label("Photo motion setup transfer is not supported yet. Its accepted video job remains available from this listing.", systemImage: "icloud")
                    .font(.rpCaption).foregroundStyle(Theme.inkDim).fixedSize(horizontal: false, vertical: true)
            } else { nativeSetupCard }
            if space == .realEstate && !listing.isSample {
                NavigationLink { ProductionPlanView(listing: listing) } label: {
                    Label("Plan recorded shots and collect takes", systemImage: "checklist").font(.rpCaption)
                }.frame(minHeight: 44)
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).modifier(RendpropContentSurface())
    }


    private func videoReviewActionLabel(_ title: String, systemImage: String, subtitle: String? = nil) -> some View {
        Group {
            if videoDynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: systemImage).font(.rpBody)
                            .foregroundStyle(Theme.accent).dynamicTypeSize(.large).accessibilityHidden(true)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.rpCaption.weight(.semibold))
                            .foregroundStyle(Theme.accent).dynamicTypeSize(.large).accessibilityHidden(true)
                    }
                    videoReviewActionText(title, subtitle: subtitle)
                }
            } else {
                HStack(spacing: 12) {
                    Image(systemName: systemImage).font(.rpBody)
                        .foregroundStyle(Theme.accent).dynamicTypeSize(.large).accessibilityHidden(true)
                    videoReviewActionText(title, subtitle: subtitle)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.rpCaption.weight(.semibold))
                        .foregroundStyle(Theme.accent).dynamicTypeSize(.large).accessibilityHidden(true)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func videoReviewActionText(_ title: String, subtitle: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.rpBody.weight(.semibold)).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle {
                Text(subtitle).font(.rpCaption).foregroundStyle(Theme.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var videoAdvancedControls: some View {
        Button { showVideoAdvanced = true } label: {
            videoReviewActionLabel("Voice & music", systemImage: "waveform",
                subtitle: (voiceMode == .off ? "Voice off" : "Voice on") + " · " + (musicSelection == nil ? "Music off" : "Music on"))
        }
        .buttonStyle(RendpropPillButtonStyle())
        .accessibilityHint("Optional. Opens voice and music choices.")
        .accessibilityIdentifier("video.advanced")
        .sheet(isPresented: $showVideoAdvanced) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        VideoMusicPicker(selection: $musicSelection, previewedTrackID: musicPreview.trackID,
                            isPreviewPlaying: musicPreview.isPlaying, previewError: musicPreview.errorMessage,
                            onStop: { musicPreview.stop() }) { track in
                            guard !recorder.isRecording else { voiceNote = "Finish your recording before previewing music."; return }
                            voPlayer?.pause()
                            musicPreview.toggle(track)
                        }
                        stepVoiceCard
                    }.padding(20)
                }
                .background(Theme.bg)
                .navigationTitle("Voice & music").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showVideoAdvanced = false } } }
            }
        }
    }

    /// The big words on the video, and which of the three looks they wear.
    ///
    /// The words themselves are written by the shot planner (one text call, no
    /// charge, no questions) — the agent picks a LOOK, not a sentence. If the
    /// planner has nothing to say the reel simply carries no shot captions; there
    /// is no state where this toggle produces an empty box on the video.
    @ViewBuilder private var bigCaptionsRow: some View {
        Toggle(isOn: $bigCaptionsOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Big words on each shot")
                    .font(.rpBody.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                Text("Three or four words a picture, written for you.")
                    .font(.rpCaption)
                    .foregroundStyle(Theme.inkDim)
            }
        }
        .tint(Theme.accent)
        if bigCaptionsOn {
            Picker("How the words look", selection: $bigCaptionStyle) {
                Text("Clean").tag(ReelComposer.ShotCaptionStyle.lowerThird)
                Text("Centred").tag(ReelComposer.ShotCaptionStyle.punchCard)
                Text("Highlight").tag(ReelComposer.ShotCaptionStyle.highlightBox)
            }
            .pickerStyle(.segmented)
        }
    }

    /// What happens between two pictures. Cut is the default and stays the
    /// default; the line underneath says out loud that it is the right answer,
    /// because a picker with three options reads as an invitation to use all
    /// three and an over-transitioned reel looks WORSE, not richer.
    private var transitionRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("BETWEEN SHOTS").font(.rpKicker).foregroundStyle(Theme.inkDim)
            Picker("Between shots", selection: $reelTransition) {
                Text("Cut").tag(ReelComposer.Transition.cut)
                Text("Blend").tag(ReelComposer.Transition.dissolve).disabled(photoMotion)
                Text("Whip").tag(ReelComposer.Transition.whip).disabled(photoMotion)
            }
            .pickerStyle(.segmented)
            Text(photoMotion ? "Photo motion uses Cut. Blend and Whip are unavailable for this mode." : "Cut is what the pros use — it's the default for a reason.")
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var formatRow: some View {
        Group {
            if videoDynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) { formatSummary; changeFormatButton }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    formatSummary
                    Spacer(minLength: 0)
                    changeFormatButton
                }
            }
        }.accessibilityIdentifier("video.deliveryFormat")
    }

    private var formatSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text((videoPurpose ?? .socialMedia).title)
                .font(.rpBody.weight(.semibold)).foregroundStyle(Theme.ink)
            Text((videoPurpose ?? .socialMedia).formatDescription)
                .font(.rpCaption).foregroundStyle(Theme.inkDim).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var changeFormatButton: some View {
        Button("Change") { setupStep = .format }
            .foregroundStyle(Theme.accent)
            .buttonStyle(RendpropPillButtonStyle())
            .disabled(isWorking || pendingBatch != nil || pendingRequest != nil || parkedClips != nil)
    }

    @ViewBuilder private var titleCardToggle: some View {
        if !portrait {
            Text("Listing videos omit the intro title and Rendprop mark. Review your own narration and text for contact or agent branding before using an MLS link.")
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
        } else { Toggle(isOn: $captionsOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Show the \(space == .realEstate ? "address" : "name") at the start")
                    .font(.rpBody.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                Text("Plus a small Rendprop mark in the corner.")
                    .font(.rpCaption)
                    .foregroundStyle(Theme.inkDim)
            }
        }
        .tint(Theme.accent)
        }
    }


    private var photoMotionModeRow: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Movement style").font(.rpBody.weight(.semibold))
            if videoDynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 10) { photoMotionModeChoices }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { photoMotionModeChoices }
                    VStack(spacing: 10) { photoMotionModeChoices }
                }
            }
            if let id = selected.first, let photo = reelPhotos.first(where: { $0.id == id }) {
                HStack(spacing: 14) {
                    if !videoDynamicTypeSize.isAccessibilitySize {
                        DetailPhotoThumb(url: photo.enhancedURL, height: 104).frame(width: 84)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous)).accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Label(photoMotion ? photoMotionDirection.title : "Camera movement", systemImage: photoMotion ? photoMotionDirection.symbol : "video")
                            .font(.rpBody.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                        Text(photoMotion ? PhotoMotionPreviewFrame.caption(direction: photoMotionDirection.rawValue, percent: photoMotionProfile.percent) : "AI creates movement within each photo.")
                            .font(.rpCaption).foregroundStyle(Theme.inkDim).fixedSize(horizontal: false, vertical: true)
                        Button { framingPreviewPhoto = photo } label: { Label("Preview framing", systemImage: "viewfinder") }
                            .font(.rpCaption.weight(.semibold)).buttonStyle(RendpropPillButtonStyle(compact: true, horizontalPadding: 12))
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Text(photoMotion ? "Uses your selected photos. No new scene or 3D travel." : "Separate rooms do not become a connected 3D tour.")
                .font(.rpCaption).foregroundStyle(Theme.inkDim).fixedSize(horizontal: false, vertical: true)
        }.accessibilityIdentifier("video.sourceMode")
    }

    @ViewBuilder private var photoMotionModeChoices: some View {
        ForEach([true, false], id: \.self) { choice in
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { photoMotion = choice }
                acknowledgedFramingKey = nil
            } label: {
                HStack(spacing: 8) {
                    Label(choice ? "Photo motion" : "AI camera", systemImage: choice ? "photo" : "sparkles")
                        .font(.rpBody.weight(.semibold)).fixedSize(horizontal: !videoDynamicTypeSize.isAccessibilitySize, vertical: true)
                    Spacer(minLength: 0)
                    if photoMotion == choice { Image(systemName: "checkmark.circle.fill").accessibilityHidden(true) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(RendpropPillButtonStyle(selected: photoMotion == choice, compact: true, horizontalPadding: 16))
            .accessibilityAddTraits(photoMotion == choice ? .isSelected : [])
            .accessibilityIdentifier(choice ? "video.mode.photoMotion" : "video.mode.ai")
        }
    }
    private var photoMotionDirectionChoices: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Direction").font(.rpBody.weight(.semibold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: videoDynamicTypeSize.isAccessibilitySize ? 260 : 140))], spacing: 10) {
                ForEach(PhotoMotionContract.Direction.allCases, id: \.rawValue) { direction in
                    Button {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { photoMotionDirection = direction }
                        acknowledgedFramingKey = nil
                    } label: {
                        Label(direction.title, systemImage: direction.symbol).font(.rpBody.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(RendpropPillButtonStyle(selected: photoMotionDirection == direction, compact: true, horizontalPadding: 14))
                    .accessibilityAddTraits(photoMotionDirection == direction ? .isSelected : [])
                }
            }
        }
    }

    private var photoMotionTimingRows: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Time on each photo").font(.rpBody.weight(.semibold))
            Text("Choose how long each photo stays on screen. Cut keeps these times exact.")
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
            ForEach(Array(selected.enumerated()), id: \.element) { index, id in
                if let photo = reelPhotos.first(where: { $0.id == id }) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 14) {
                            DetailPhotoThumb(url: photo.enhancedURL, height: 104).frame(width: 84)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous)).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Photo \(index + 1)").font(.rpCaption.weight(.semibold)).foregroundStyle(Theme.accent)
                                Text(videoPhotoVersions[id]?.title ?? "Saved photo").font(.rpBody.weight(.semibold))
                                    .fixedSize(horizontal: false, vertical: true)
                                Text("\(photoMotionFrameCount(id) / 24) seconds").font(.rpBody).foregroundStyle(Theme.inkDim)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 64))], spacing: 8) {
                            ForEach(PhotoMotionContract.frames, id: \.self) { frames in
                                Button("\(frames / 24)s") { if let key = photoMotionKey(id) { photoMotionFrames[key] = frames } }
                                    .disabled(photoMotionKey(id) == nil)
                                    .buttonStyle(RendpropPillButtonStyle(selected: photoMotionFrameCount(id) == frames, compact: true, horizontalPadding: 10))
                                    .accessibilityLabel("Photo \(index + 1), \(frames / 24) seconds")
                                    .accessibilityAddTraits(photoMotionFrameCount(id) == frames ? .isSelected : [])
                            }
                        }
                    }
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.fillSubtle, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
            }
            if reelTransition != .cut { Text("Choose Cut below to use Photo motion. Blend and Whip are not supported yet.").font(.rpCaption).foregroundStyle(Theme.warn) }
            if bigCaptionsOn { Text("Turn off AI picture labels below to use Photo motion without new AI planning.").font(.rpCaption).foregroundStyle(Theme.warn) }
            if !selectedExtras.isEmpty || listing.isSample { Text("Photo motion requires saved listing photos without an extra opening clip.").font(.rpCaption).foregroundStyle(Theme.warn) }
        }.accessibilityIdentifier("video.photoMotion.timing")
        .task(id: selectedPhotoMotionInputs) {
            let inputs = selectedPhotoMotionInputs, actor = auth.userID, epoch = auth.syncSessionRevision, org = WorkspaceContext.selectedOrgID
            let digests = await Task.detached(priority: .utility) {
                Dictionary(uniqueKeysWithValues: inputs.compactMap { input in DirectUploader.sha256(of: input.url).map { (input, $0) } })
            }.value
            guard !Task.isCancelled, photoMotion, inputs == selectedPhotoMotionInputs, actor == auth.userID,
                  epoch == auth.syncSessionRevision, org == WorkspaceContext.selectedOrgID else { return }
            photoMotionDigests = digests
        }
    }

    private var motionRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Camera motion", systemImage: "video")
                .font(.rpBody.weight(.semibold)).foregroundStyle(Theme.ink)
            motionChoice(nil)
            if videoDynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 10) {
                    ForEach(ReelCameraMove.allCases, id: \.rawValue) { move in motionChoice(move) }
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 148), spacing: 10)], spacing: 10) {
                    ForEach(ReelCameraMove.allCases, id: \.rawValue) { move in motionChoice(move) }
                }
            }
            Text(cameraMove == nil ? "A gentle, varied move is chosen for each photo." : "This move applies to each selected photo.")
                .font(.rpCaption).foregroundStyle(Theme.inkDim).fixedSize(horizontal: false, vertical: true)
            Text("Motion stays within the photo. Preview the crop before creating.")
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
            Text(costText).font(.rpCaption).foregroundStyle(Theme.inkDim)
        }
    }

    private func motionChoice(_ move: ReelCameraMove?) -> some View {
        let chosen = cameraMove == move
        return Button {
            withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8)) {
                cameraMove = move
            }
            Haptics.selection()
        } label: {
            HStack(spacing: 9) {
                ReelMotionCue(move: move, selected: chosen)
                VStack(alignment: .leading, spacing: 2) {
                    Text(move?.title ?? "Automatic").font(.rpCaption.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if move == nil { Text("Varied for each photo").font(.rpCaption).foregroundStyle(Theme.inkDim) }
                }
                Spacer(minLength: 0)
                if chosen { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent).accessibilityHidden(true) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(RendpropPillButtonStyle(selected: chosen, compact: true, horizontalPadding: 12))
        .accessibilityLabel(move?.title ?? "Automatic motion, varied for each photo")
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .accessibilityIdentifier(move.map { "reel.motion.\($0.rawValue)" } ?? "video.motion.automatic")
    }

    private var makeButton: some View {
        Button { generate() } label: {
            Label(generateTitle, systemImage: "sparkles")
                .font(.rpBody.weight(.semibold))
                .frame(maxWidth: .infinity).frame(minHeight: 24)
        }
        .modifier(RendpropActionAppearance())
        .disabled(!canGenerate || checkingFraming)
        .accessibilityIdentifier("phase1.reelGenerate")
    }

    private var aiDisclosureLine: some View {
        Text("Review your finished video before publishing.")
            .font(.rpCaption).foregroundStyle(Theme.inkDim)
            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
    }

    /// Clips from a run that stopped before the stitch — already generated,
    /// already charged, and now sitting in `reels/<id>-parked/`. This card offers
    /// the free half of the job (the on-device stitch) instead of making the
    /// agent buy the same clips a second time.
    ///
    /// The wording says the money part out loud. In the 4,000 sq ft field test
    /// the clips were deleted with no message at all, and the only signal the
    /// agent had was his credit balance.
    /// Parked clips that are really still on disk. A record whose files went away
    /// (Clear local data) must not put a card on screen offering to stitch them.
    private var parkedClipCount: Int { parkedClips?.clipURLs.count ?? 0 }

    @ViewBuilder private var parkedClipsCard: some View {
        if parkedClipCount > 0 {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("UNFINISHED VIDEO").font(.rpKicker).foregroundStyle(Theme.accent)
                    Spacer(minLength: 8)
                    Text("\(parkedClipCount) clip\(parkedClipCount == 1 ? "" : "s")")
                        .font(.rpCaption).foregroundStyle(Theme.inkDim)
                }
                Text("You already made \(parkedClipCount) AI clip\(parkedClipCount == 1 ? "" : "s") for this \(space.spaceNoun) and they're saved on this phone. Joining them into a video happens here and uses no new AI generation.")
                    .font(.rpCaption).foregroundStyle(Theme.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
                Button { finishParkedReel() } label: {
                    Label("Finish that video", systemImage: "film.stack")
                        .font(.rpBody.weight(.semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .modifier(RendpropActionLabelSurface(primary: true))
                }
                .buttonStyle(ScalePressStyle())
                .accessibilityLabel(Text("Finish that video from the clips you already paid for"))
                Button("Discard those clips", role: .destructive) {
                    showDiscardParkedConfirm = true
                }
                .font(.rpCaption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
    }

    /// The reel this listing already has (F-A-23) — playable, shareable and
    /// savable without spending another round of AI clips. Making a new one
    /// keeps working exactly as before; the old file is only pruned once a new
    /// reel has landed.
    @ViewBuilder private var lastReelCard: some View {
        if let url = lastReel {
            VStack(alignment: .leading, spacing: 10) {
                Text("YOUR LAST VIDEO").font(.rpKicker).foregroundStyle(Theme.inkDim)
                Button { openExistingReel(url) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(Color.white)
                            .frame(width: 40, height: 40)
                            .background(RPGradient.reel,
                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Play, save or share it")
                                .font(.rpBody.weight(.semibold))
                                .foregroundStyle(Theme.ink)
                            Text(Self.reelDateLabel(url))
                                .font(.rpCaption).foregroundStyle(Theme.inkDim)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.rpCaption.weight(.bold)).foregroundStyle(Theme.inkDim)
                    }
                    .padding(10)
                    .background(Theme.fillSubtle,
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(ScalePressStyle())
                Text("Making a new video creates fresh clips. Your recent videos stay on this phone.")
                    .font(.rpCaption).foregroundStyle(Theme.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
    }

    /// Ready-made clips (the aerial intro) that lead the reel — toggleable.
    private var clipsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CLIPS").font(.rpKicker).foregroundStyle(Theme.inkDim)
            ForEach(extraClipURLs, id: \.self) { url in
                let on = selectedExtras.contains(url)
                Button {
                    if let i = selectedExtras.firstIndex(of: url) {
                        selectedExtras.remove(at: i)
                    } else {
                        selectedExtras.append(url)
                    }
                    Haptics.selection()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "airplane.departure")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.white)
                            .frame(width: 40, height: 40)
                            .background(RPGradient.aerial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Aerial intro").font(.rpBody.weight(.semibold)).foregroundStyle(Theme.ink)
                            Text("Opens the video · AI-generated").font(.rpCaption).foregroundStyle(Theme.inkDim)
                        }
                        Spacer()
                        Image(systemName: on ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 20))
                            .foregroundStyle(on ? Theme.accent : Theme.inkDim)
                    }
                    .padding(10)
                    .background(Theme.fillSubtle, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(ScalePressStyle())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var generateTitle: String {
        if let narrationPreparationMessage { return narrationPreparationMessage }
        if canGenerate { return "Make my video" }
        if includeAcceptedOpening, acceptedOpening != nil, !photoMotion { return "Choose Photo motion or turn opening off" }
        if photoMotion, reelTransition != .cut { return "Choose Cut first" }
        if photoMotion, bigCaptionsOn { return "Turn off AI picture labels" }
        if photoMotion, !selected.isEmpty, selected.contains(where: { photoMotionKey($0) == nil }) { return "Checking selected photo versions…" }
        // A retained request is the reason, not the photo count — say so.
        if pendingRequest != nil || unreadablePendingContext != nil { return "Review the saved request first" }
        if selected.count > VideoSelectionCapacity.maximumPhotos || totalSelected > VideoSelectionCapacity.maximumClips {
            return "Pick \(VideoSelectionCapacity.maximumPhotos) photos at most"
        }
        if !selectedExtras.isEmpty { return "Pick 1 more photo" }
        return "Pick 2 photos first"
    }

    private var costText: String {
        // No per-unit dollar figures in UI while IAP is off (App Store 3.1.1).
        if photoMotion { return selected.isEmpty ? "Choose 2–5 seconds for each selected photo." : String(format: chosenOpening == nil ? "%d photos · %.2f seconds" : "Opening and %d photos · %.2f seconds", selected.count, Double(selectedTimelineFrames) / 24) }
        guard !selected.isEmpty else { return "Every photo you pick becomes 5 seconds of video." }
        return "\(selected.count) photo\(selected.count == 1 ? "" : "s") picked — that's \(selected.count * 5) seconds of video."
    }

    private var generatingSection: some View {
        VStack(spacing: 14) {
            if work.usesPhotoMotion { ProgressView().tint(Theme.accent).accessibilityLabel(statusText) }
            else { ProgressView(value: work.fraction).tint(Theme.accent) }
            Text(statusText)
                .font(.rpHeadline)
                .foregroundStyle(Theme.ink)
            Text(work.serverJob?.reply != nil ? "Your photos are safely uploaded. Rendering continues on our servers even if you close Rendprop. We’ll notify you when it is ready; reopen this listing to review." : work.serverJob != nil ? "Your request is saved. Check status to confirm server acceptance before starting another video." : "Keep Rendprop open while photos, optional narration and the exact recipe upload. After the server accepts the job, you can leave the app while it renders.")
                .font(.rpCaption)
                .foregroundStyle(Theme.inkDim)
                .multilineTextAlignment(.center)
            if failedClips > 0 {
                Text("Clip generation stopped. Finished clips are kept on this phone.")
                    .font(.rpCaption)
                    .foregroundStyle(Theme.warn)
                clipFailureDetails
            }
            if work.serverJob != nil {
                serverStatusControls
            }
            Button("Cancel", role: .destructive) { cancelWork() }
                .font(.rpBody)
                .padding(.top, 6)
            // Say the money part out loud. Cancelling used to delete every clip
            // already generated and charged for, silently (the 4,000 sq ft field
            // test); now it keeps them and this line promises so before the tap.
            Text(work.serverJob != nil ? "Cancel stops future clip requests. Work already dispatched may still be charged; your saved photos stay unchanged." : "Cancelling keeps the clips you've already paid for — you can finish the video from them later.")
                .font(.rpCaption)
                .foregroundStyle(Theme.inkDim)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var serverStatusControls: some View {
        VStack(spacing: 8) {
            SecondaryButton(title: work.isCheckingServerStatus ? "Refreshing…" : "Refresh status",
                            systemImage: "arrow.clockwise",
                            isDisabled: work.isCheckingServerStatus,
                            isLoading: work.isCheckingServerStatus) {
                PropertyVideoJobRunner.shared.checkNow(work)
            }
            .accessibilityIdentifier("video.status.refresh")
            if let checked = work.lastServerStatusCheck {
                Text("Last checked \(checked.formatted(date: .omitted, time: .standard))")
                    .font(.rpCaption).foregroundStyle(Theme.inkDim)
            }
            Text(work.serverStatusCheckNote ?? "Updates automatically while Rendprop is open.")
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
                .multilineTextAlignment(.center)
        }
    }

    private var stitchingSection: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(1.3)
                .padding(.top, 16)
            Text("Putting your video together…")
                .font(.rpHeadline)
                .foregroundStyle(Theme.ink)
            Text("Joining everything into one \(portrait ? "tall" : "wide") video, here on your phone.")
                .font(.rpCaption)
                .foregroundStyle(Theme.inkDim)
                .multilineTextAlignment(.center)
            if failedClips > 0 {
                Text("\(failedClips) clip\(failedClips == 1 ? "" : "s") failed — the video uses the rest.")
                    .font(.rpCaption)
                    .foregroundStyle(Theme.warn)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var reelResultAspect: CGFloat {
        measuredReelAspect ?? (portrait ? 9.0 / 16.0 : 16.0 / 9.0)
    }

    @State private var selectingWebsiteVideo = false
    @State private var websiteVideoNote: String?

    private func chooseWebsiteVideo(_ url: URL) {
        guard !selectingWebsiteVideo, !listing.isSample else { return }
        selectingWebsiteVideo = true; websiteVideoNote = nil
        Task {
            defer { selectingWebsiteVideo = false }
            do {
                let record = try ListingVideoStore.load(for: url)
                try await model.selectWebsiteVideo(record, for: listing.id)
                websiteVideoNote = "Selected for the listing website. Return to the listing and tap Publish or Republish to make it live."
                Haptics.success()
            } catch { websiteVideoNote = AppModel.userMessage(for: error) }
        }
    }

    private struct SavedVideoIdentityHeader: View {
        let record: ListingVideoRecord?
        let fallbackDateLabel: String

        var body: some View {
            VStack(spacing: 6) {
                Label("Saved video", systemImage: "clock.arrow.circlepath")
                    .font(.rpHeadline).foregroundStyle(Theme.ink)
                    .accessibilityIdentifier("video.saved.heading")
                Text(record.map { "Made \($0.createdAt.formatted(date: .abbreviated, time: .shortened))" } ?? fallbackDateLabel)
                    .font(.rpCaption).foregroundStyle(Theme.inkDim)
                    .accessibilityIdentifier("video.saved.date")
                Text(record?.savedPlaybackMotionLabel ?? "Motion details unavailable")
                    .font(.rpCaption.weight(.semibold)).foregroundStyle(Theme.accent)
                    .accessibilityIdentifier("video.saved.motion")
                if let duration = record?.durationS, duration.isFinite, duration > 0 {
                    Text("\(duration.formatted(.number.precision(.fractionLength(0...1)))) seconds")
                        .font(.rpCaption).foregroundStyle(Theme.inkDim)
                }
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var doneSection: some View {
        VStack(spacing: 12) {
            if work.restoredRetainedResult, let url = reelURL {
                SavedVideoIdentityHeader(record: try? ListingVideoStore.load(for: url), fallbackDateLabel: Self.reelDateLabel(url))
            } else {
                if work.serverJob?.request.isPhotoMotion == true {
                    Text("Photo motion · \(work.serverJob!.request.sources.reduce(0) { $0 + ($1.visibleFrames ?? 0) } / 24)s")
                        .font(.rpCaption.weight(.semibold)).foregroundStyle(Theme.accent)
                }
                Label("Your video is ready", systemImage: "checkmark.circle.fill")
                    .font(.rpHeadline)
                    .foregroundStyle(Theme.good)
            }
            if originalPhotoMotionShots > 0 {
                Text("Used still photo on \(originalPhotoMotionShots) shot\(originalPhotoMotionShots == 1 ? "" : "s"). Those shots use the selected photo unchanged, including any photo edits you selected.")
                    .font(.rpCaption).foregroundStyle(Theme.inkDim)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("reel.originalPhotoMotionSummary")
            }
            if failedClips > 0 {
                Text("\(failedClips) clip\(failedClips == 1 ? "" : "s") failed — the video uses the rest.")
                    .font(.rpCaption)
                    .foregroundStyle(Theme.warn)
            }
            if let player {
                VideoPlayer(player: player)
                    .aspectRatio(reelResultAspect, contentMode: .fit)
                    .frame(maxWidth: 460 * reelResultAspect)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                    .onAppear { player.play() }
                    .task(id: reelURL) {
                        guard let url = reelURL else { return }
                        measuredReelAspect = nil
                        let owner = auth.userID, revision = auth.syncSessionRevision
                        guard let ratio = await Self.reelDisplayAspect(url), !Task.isCancelled,
                              reelURL == url, auth.userID == owner, auth.syncSessionRevision == revision else { return }
                        measuredReelAspect = ratio
                    }
            }
            if let reelURL {
                if !listing.isSample, let record = try? ListingVideoStore.load(for: reelURL), record.canSelectForWebsite {
                    Button { chooseWebsiteVideo(reelURL) } label: {
                        Label(selectingWebsiteVideo ? "Checking the saved video…" : "Use on listing website", systemImage: "globe")
                            .font(.rpBody.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 14)
                            .modifier(RendpropActionLabelSurface(primary: true))
                    }.disabled(selectingWebsiteVideo).accessibilityIdentifier("video.useOnWebsite")
                }
                if let websiteVideoNote { Text(websiteVideoNote).font(.rpCaption).foregroundStyle(Theme.inkDim) }
                Button { saveToPhotos(reelURL) } label: {
                    Label(savedToPhotos ? "Saved to Photos" : "Save to Photos",
                          systemImage: savedToPhotos ? "checkmark.circle.fill" : "square.and.arrow.down")
                        .font(.rpBody.weight(.semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .modifier(RendpropActionLabelSurface(primary: true))
                }
                .disabled(savedToPhotos || isSaving)

                ShareLink(item: reelURL) {
                    Label("Share video", systemImage: "square.and.arrow.up")
                        .font(.rpBody.weight(.semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 13)
                        .modifier(RendpropActionLabelSurface(primary: false))
                }
            }
            if let saveError {
                Text(saveError)
                    .font(.rpCaption)
                    .foregroundStyle(Theme.warn)
                    .multilineTextAlignment(.center)
            }
            Button("Make another one") { resetToSetup() }
                .font(.rpBody)
                .foregroundStyle(Theme.inkDim)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var failedSection: some View {
        if work.serverJob != nil { serverVideoAttentionSection } else {
        VStack(spacing: 12) {
            if let failure {
                AIFailureCard(failure: failure,
                              retryHint: "No more photos were sent after the failure. Finished clips are kept on this phone.",
                              quotaFeature: "reels",
                              onReconnect: { connection.run { resetToSetup() } })
            } else {
                Label("Couldn't make the video", systemImage: "exclamationmark.triangle")
                    .font(.rpHeadline)
                    .foregroundStyle(Theme.warn)
            }
            clipFailureDetails
            pendingRequestCard
            if let parkedClips {
                Text("\(parkedClips.clipURLs.count) finished clip\(parkedClips.clipURLs.count == 1 ? " is" : "s are") saved. You can finish a shorter video from those clips without generating again.")
                    .font(.rpCaption).foregroundStyle(Theme.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
                PrimaryButton(title: "Finish video from saved clips", systemImage: "film.stack") {
                    finishParkedReel()
                }
                    .accessibilityIdentifier("reel.finish-saved-clips")
            }
            SecondaryButton(title: "Back to video setup", systemImage: "slider.horizontal.3") {
                resetToSetup()
            }
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
    }

    private var serverVideoAttentionSection: some View {
        VStack(spacing: 14) {
            Label("Your video request is saved", systemImage: "icloud").font(.rpHeadline)
            if let failure { Text(failure.message).font(.rpCaption).foregroundStyle(Theme.inkDim) }
            Text(work.serverJob?.wasRefusedBeforeAdmission == true ? "This video was not admitted. Choose fewer photos or check your plan; your saved photos and rejected recipe are kept." : "Check this same request before starting again. Leaving Rendprop does not cancel an accepted server job.")
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
            if work.serverJob?.reply != nil {
                serverStatusControls
            }
            if work.serverJob?.mayReplaceAfterResolution == true, work.serverJob?.reply == nil {
                PrimaryButton(title: "Edit photos and setup", systemImage: "photo.on.rectangle") {
                    resetToSetup()
                }
                .accessibilityIdentifier("video.server.editRefused")
            } else if work.serverJob?.reply?.isTerminal == true {
                if work.serverJob?.reply?.mayResume == true && work.serverJob?.reply?.resumeConsentToken != nil && work.serverJob?.stopRequested != true {
                    PrimaryButton(title: "Resume saved video", systemImage: "play.fill") {
                        Task { await PropertyVideoJobRunner.shared.resume(work) }
                    }
                    .accessibilityIdentifier("video.server.resume")
                    Text("Uses the same photos and finished clips. Your current plan is checked before more clips start.")
                        .font(.rpCaption).foregroundStyle(Theme.inkDim)
                }
                if work.serverJob?.reply?.mayResume == true && work.serverJob?.reply?.resumeConsentToken == nil {
                    Text(PropertyVideoProcessorFailure.unknownSavedAuthority.localizedDescription).font(.rpCaption).foregroundStyle(Theme.inkDim)
                }
                SecondaryButton(title: "Back to video setup", systemImage: "slider.horizontal.3") { resetToSetup() }
            } else {
                PrimaryButton(title: "Check saved job", systemImage: "arrow.clockwise") {
                    phase = .generating; PropertyVideoJobRunner.shared.checkNow(work)
                }
                .accessibilityIdentifier("video.server.check")
                Button("Cancel saved job", role: .destructive) { Task { await PropertyVideoJobRunner.shared.cancel(work) } }
            }
        }.padding(.vertical, 24)
    }

    private var clipFailureDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(clipIssues) { issue in
                Text("Photo \(issue.photoNumber): \(issue.failure.message)")
                    .font(.rpCaption).foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("reel.clip-failures")
    }

    // MARK: Step 2 — your voice (optional; docs/VOICEOVER-CONTRACT.md)
    //
    // Every body here is deliberately tiny: the build hit a type-checker timeout
    // on a big body in THIS file once, so the voiceover UI is split across many
    // small @ViewBuilder sub-views and helpers rather than one large block, and
    // `setupSection` only names `stepVoiceCard`.

    /// Step 2. A numbered, named step — not a card someone has to notice. It
    /// holds the Off / My voice / AI voice picker, one plain line explaining
    /// the chosen mode, the matching pane, and (once a take exists) playback +
    /// the caption toggle.
    @ViewBuilder private var stepVoiceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("OPTIONAL NARRATION").font(.rpKicker).foregroundStyle(Theme.accent)
            Text("Add your voice or an AI voice. Spoken captions are optional and follow the narration.")
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
            voiceModePicker
            voiceModeHint
            switch voiceMode {
            case .off:     EmptyView()
            case .myVoice: myVoicePane
            case .aiVoice: aiVoicePane
            }
            voiceoverReadyRow
            if let voiceError {
                Text(voiceError)
                    .font(.rpCaption).foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let voiceNote {
                Text(voiceNote)
                    .font(.rpCaption).foregroundStyle(Theme.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .accessibilityIdentifier("reel.step.voice")
    }

    private var voiceModePicker: some View {
        Picker("Voiceover", selection: $voiceMode) {
            Text("Off").tag(VoiceMode.off)
            Text("My voice").tag(VoiceMode.myVoice)
            Text("AI voice").tag(VoiceMode.aiVoice)
        }
        .pickerStyle(.segmented)
    }

    /// One child-simple line per mode, so the three words on the picker are
    /// never the only explanation.
    private var voiceModeHint: some View {
        Text(Self.voiceModeHintText(voiceMode))
            .font(.rpCaption).foregroundStyle(Theme.inkDim)
            .fixedSize(horizontal: false, vertical: true)
    }

    private static func voiceModeHintText(_ mode: VoiceMode) -> String {
        switch mode {
        case .off:     return "No narration. Optional music is separate."
        case .myVoice: return "Record yourself. Your words become captions on the video."
        case .aiVoice: return "Type it, AI reads it. Your words become captions on the video."
        }
    }

    // --- My voice: record → on-device transcription ---

    @ViewBuilder private var myVoicePane: some View {
        VStack(alignment: .leading, spacing: 10) {
            if recorder.isRecording {
                levelMeter(recorder.level)
                Text(timeLabel(recorder.elapsed))
                    .font(.rpBody.weight(.semibold)).foregroundStyle(Theme.ink)
                recordButton("Stop", "stop.fill", Theme.warn)
            } else if isTranscribing {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Writing your captions on this phone…")
                        .font(.rpCaption).foregroundStyle(Theme.inkDim)
                }
            } else {
                recordButton(voiceover == nil ? "Record" : "Record again",
                             "mic.fill", Theme.accent)
                // Honest: SpeechTranscriber runs on-device when the model is
                // there and falls back to Apple's speech service when it isn't,
                // so this must not promise "nothing leaves the phone".
                Text("Tap once to start. Tap again to stop. Apple turns your words into captions.")
                    .font(.rpCaption).foregroundStyle(Theme.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The one button this step is about — big, filled, unmissable.
    private func recordButton(_ title: String, _ icon: String, _ tint: Color) -> some View {
        Button { recordTapped() } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 22, weight: .bold))
                Text(title).font(.rpHeadline)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 20)
            .background(tint)
            .foregroundStyle(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(ScalePressStyle())
        .disabled(isTranscribing || requestingVoicePermission)
        .accessibilityLabel(Text(recorder.isRecording ? "Stop recording" : "Record your voice"))
    }

    private func levelMeter(_ level: Float) -> some View {
        let fraction = CGFloat(min(max(level, 0), 1))
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.fillSubtle)
                Capsule().fill(Theme.accent)
                    .frame(width: max(4, geo.size.width * fraction))
            }
        }
        .frame(height: 6)
        .animation(.linear(duration: 0.05), value: level)
    }

    // --- AI voice: script + voice → ElevenLabs (spends money; session awaited) ---

    // Every body here stays tiny on purpose — see the note above
    // `stepVoiceCard`. `aiVoicePane` is a list of identifiers and nothing else.
    @ViewBuilder private var aiVoicePane: some View {
        VStack(alignment: .leading, spacing: 14) {
            aiVoiceScriptCard
            aiVoicePicker
            makeVoiceButton
        }
    }

    private var aiVoiceScriptCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Label("Your script", systemImage: "text.alignleft")
                    .font(.rpBody.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 8)
                toneMenu
            }
            scriptAssistRow
            scriptField
            scriptLengthRow
            scriptLengthNote
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// "Write my script" — wearing the same clothes as "✨ Improve my prompt" in
    /// the photo studio on purpose. They are one feature in two places: the AI
    /// writes the words, the person edits them. Anyone who has used one should
    /// recognise the other on sight.
    @ViewBuilder private var scriptAssistRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { writeScript() } label: {
                HStack(spacing: 8) {
                    if scriptInFlight {
                        ProgressView().tint(Theme.accent)
                        Text("Writing your script…")
                    } else {
                        Image(systemName: "sparkles")
                        Text("Write my script")
                    }
                }
                .font(.rpBody.weight(.semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 13)
                .modifier(RendpropActionLabelSurface(primary: false))
            }
            .buttonStyle(ScalePressStyle())
            .disabled(scriptInFlight || ttsInFlight)
            .accessibilityIdentifier("reel.script.write")
            Text("Uses this \(space.spaceNoun)'s details. You can edit every word.")
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Tone lives HERE — one small menu beside the explanation line, not a step
    /// of its own and not a question anybody has to answer. The default already
    /// suits the space type.
    private var toneMenu: some View {
        Menu {
            Picker("Tone", selection: $tone) {
                ForEach(ScriptTone.allCases, id: \.self) { t in
                    Text(t.label).tag(t)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(tone.label)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .font(.rpCaption.weight(.semibold))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Theme.accentSoft, in: Capsule())
        }
        .disabled(scriptInFlight)
        .accessibilityLabel(Text("How the script should sound"))
        .accessibilityValue(Text(tone.label))
    }

    private var scriptField: some View {
        TextField("Write what you'd like your narrator to say…",
                  text: $aiScript, axis: .vertical)
            .font(.rpBody)
            .lineLimit(3...6)
            .textFieldStyle(.plain)
            .padding(12)
            .background(Theme.fillSubtle, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .disabled(ttsInFlight || scriptInFlight)
            .accessibilityLabel(Text("Narration script"))
            .accessibilityIdentifier("reel.script.field")
    }

    /// Live length, in BOTH units that matter: characters against the server's
    /// hard 1,000-char cap, and seconds against the reel this script has to fit.
    ///
    /// Show the estimate before voice generation. Background video jobs verify
    /// the actual narration duration before starting clips and refuse a take
    /// that doesn't fit; this estimate does not change that authority. Same
    /// shape as the 600-char counter in `CustomEditSheet`.
    private var scriptLengthRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Self.scriptLengthLabel(count: aiScript.count,
                                        readSeconds: scriptReadSeconds,
                                        reelSeconds: reelSeconds,
                                        budget: scriptBudget))
                .font(.rpCaption)
                .foregroundStyle(scriptOverrunsReel ? Theme.warn : Theme.inkDim)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Text("\(aiScript.count)/\(Self.scriptCharacterCap)")
                .font(.rpCaption)
                .foregroundStyle(aiScript.count > Self.scriptCharacterCap ? Theme.warn : Theme.inkDim)
        }
    }

    /// The plain-words consequence, and only when there IS one. A warning, never
    /// a block: the script is the agent's, and "this will look like X" is the
    /// app's job — deciding for them is not.
    @ViewBuilder private var scriptLengthNote: some View {
        if aiScript.count > Self.scriptCharacterCap {
            Text("That's longer than \(Self.scriptCharacterCap) characters, which is the most the AI voice reads in one go. Trim it or making the voice will fail.")
                .font(.rpCaption).foregroundStyle(Theme.warn)
                .fixedSize(horizontal: false, vertical: true)
        } else if scriptOverrunsReel {
            Text("This takes about \(Self.wholeSeconds(scriptReadSeconds)) seconds to read and your video is \(reelSeconds) seconds long. Shorten the narration or add photos so the voice fits before creating your video.")
                .font(.rpCaption).foregroundStyle(Theme.warn)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var makeVoiceButton: some View {
        Button { generateAIVoice() } label: {
            Label(ttsInFlight ? "Making voice…" : "Make voice", systemImage: "waveform")
                .font(.rpBody.weight(.semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 16)
                .modifier(RendpropActionLabelSurface())
        }
        .buttonStyle(ScalePressStyle())
        .disabled(!aiCanGenerate)
        .accessibilityIdentifier("reel.voice.make")
    }

    @ViewBuilder private var aiVoicePicker: some View {
        if loadingVoices {
            HStack(spacing: 8) {
                ProgressView()
                Text("Getting the voices…").font(.rpCaption).foregroundStyle(Theme.inkDim)
            }
        } else if aiVoices.isEmpty {
            Button("Load voices") { loadVoices() }
                .font(.rpCaption.weight(.semibold)).foregroundStyle(Theme.accent)
        } else {
            Menu {
                Picker("Voice", selection: $selectedVoiceID) {
                    ForEach(aiVoices) { v in
                        Text(voiceRowLabel(v)).tag(v.voiceID)
                    }
                }
            } label: {
                selectedVoiceLabel
            }
            .accessibilityLabel(Text("Narrator voice"))
            .accessibilityValue(Text(selectedAIVoice.map(voiceRowLabel) ?? "Choose a voice"))
            .accessibilityHint(Text("Choose who reads your script"))
            .accessibilityIdentifier("reel.voice.picker")
        }
    }

    private var selectedAIVoice: AIVoice? {
        aiVoices.first { $0.voiceID == selectedVoiceID }
    }

    private var selectedVoiceLabel: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 44, height: 44)
                .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Narrator").font(.rpCaption).foregroundStyle(Theme.inkDim)
                Text(selectedAIVoice.map(voiceDisplayName) ?? "Choose a voice")
                    .font(.rpBody.weight(.semibold)).foregroundStyle(Theme.ink)
                    .lineLimit(1)
                if let selectedAIVoice {
                    Text(voiceShortDescription(selectedAIVoice))
                        .font(.rpCaption).foregroundStyle(Theme.inkDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.inkDim)
                .accessibilityHidden(true)
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func voiceRowLabel(_ v: AIVoice) -> String {
        "\(voiceDisplayName(v)) · \(voiceShortDescription(v))"
    }

    /// Presentation only: the catalogue's id and server metadata stay intact.
    private func voiceDisplayName(_ voice: AIVoice) -> String {
        let name = voice.displayName
        guard let suffix = name.range(of: #"\s+[-–—|]\s*"#, options: .regularExpression) else { return name }
        let friendly = String(name[..<suffix.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return friendly.isEmpty ? name : friendly
    }

    private func voiceShortDescription(_ voice: AIVoice) -> String {
        let metadata = "\(voice.displayName) \(voice.subtitle)".lowercased().replacingOccurrences(of: "_", with: " ")
        let words = Set(metadata.components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty })
        let styles = [("warm", "Warm"), ("friendly", "Friendly"), ("calm", "Calm"),
                      ("confident", "Confident"), ("dominant", "Confident"), ("firm", "Confident"),
                      ("bright", "Bright"), ("soft", "Soft"), ("deep", "Deep"), ("expressive", "Expressive")]
        let accents = [("american", "American accent"), ("british", "British accent"),
                       ("australian", "Australian accent"), ("irish", "Irish accent"),
                       ("scottish", "Scottish accent"), ("canadian", "Canadian accent")]
        let style = styles.first { words.contains($0.0) }?.1
        let accent = accents.first { words.contains($0.0) }?.1
        let description = [style, accent].compactMap { $0 }.joined(separator: " · ")
        return description.isEmpty ? "Narration voice" : description
    }

    private var aiCanGenerate: Bool {
        // `!scriptInFlight` is an in-flight guard, not a new gate: spending money
        // on the voice while the script field is about to be replaced under the
        // agent would speak the OLD words. Sign-in, consent and quota are all
        // exactly where they were.
        !ttsInFlight && !scriptInFlight && !selectedVoiceID.isEmpty
            && aiScript.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
    }

    // MARK: Script length — the constraint, made visible

    /// The server's hard cap on one TTS call (`aiVoiceTTS`, contract §). Shown,
    /// never silently enforced: `aiScript` can be seeded with the transcript of
    /// a recording the agent actually made, and truncating THAT on sight would
    /// destroy the one thing the app cannot regenerate.
    private static let scriptCharacterCap = 1_000

    /// How long the finished reel runs, in seconds.
    ///
    /// Every AI clip is generated at a FIXED 5 s (`makeClip` submits
    /// `seconds: 5`), so the reel is 5 s per selected item. The ready-made
    /// extras — today only the aerial intro — are counted at 5 s too; a real
    /// aerial is 4–8 s, so this can be a couple of seconds out on a reel that
    /// has one. That is fine for its only job, which is telling a person
    /// roughly how many words fit; nothing in the export is laid out on it.
    private var reelSeconds: Int { photoMotion ? Int(ceil(Double(selectedTimelineFrames) / 24)) : 5 * totalSelected }

    /// What the script is written to fit — the reel's length, inside the
    /// contract's supported 10…45 s window.
    private var targetSeconds: Int { min(45, max(10, reelSeconds)) }

    /// Roughly how long `aiScript` takes to read aloud.
    private var scriptReadSeconds: Double {
        Double(aiScript.count) / AIScriptResult.charactersPerSecond
    }

    /// The character budget that fits the reel exactly — what to aim for when
    /// the box is still empty.
    private var scriptBudget: Int {
        min(Self.scriptCharacterCap, Int(Double(reelSeconds) * AIScriptResult.charactersPerSecond))
    }

    /// True when the voice will still be talking after the last picture. The
    /// half-second of slack keeps a script that lands on the line from flashing
    /// a warning at every keystroke.
    private var scriptOverrunsReel: Bool {
        reelSeconds > 0 && scriptReadSeconds > Double(reelSeconds) + 0.5
    }

    /// The line above the counter. `nonisolated` and pure — it is called from a
    /// view property rather than from `body`, so it must not be isolated to the
    /// main actor by inference (that mismatch has broken this build before).
    nonisolated private static func scriptLengthLabel(count: Int, readSeconds: Double,
                                                      reelSeconds: Int, budget: Int) -> String {
        guard reelSeconds > 0 else {
            return "Pick your photos first — then this shows how long the script can be."
        }
        if count == 0 {
            return "About \(budget) characters fits your \(reelSeconds)-second reel."
        }
        return "About \(wholeSeconds(readSeconds))s to read · your video is \(reelSeconds)s"
    }

    nonisolated private static func wholeSeconds(_ seconds: Double) -> Int {
        // Clamped before the conversion: `Int(someHugeDouble)` traps, and this
        // number only ever gets printed in a sentence.
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int(min(seconds, 86_400).rounded())
    }

    // MARK: Tone

    /// Which tone suits which trade. A home is a place somebody will live in; a
    /// store has ten seconds to get a person off a couch; a venue is selling an
    /// occasion. `nonisolated` and pure — it reads nothing but its argument.
    nonisolated private static func defaultTone(for space: SpaceType) -> ScriptTone {
        switch space {
        case .realEstate: return .warm
        case .venue:      return .luxury
        case .restaurant: return .warm
        case .retail:     return .punchy
        case .fitness:    return .punchy
        case .other:      return .warm
        }
    }

    // --- Finished take: playback + caption toggle (maps to CaptionStyle) ---

    @ViewBuilder private var voiceoverReadyRow: some View {
        // Only while a mode is active: `.off` means "no voiceover", and that is
        // exactly what generate() uses — so a take isn't shown as "ready" when
        // the reel would drop it. The take itself is preserved across a switch.
        if voiceMode != .off, let vo = voiceover {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.good)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(vo.source == .aiVoice ? "AI voice is ready" : "Your voice is ready")
                            .font(.rpBody.weight(.semibold)).foregroundStyle(Theme.ink)
                        Text(readyDetail(vo)).font(.rpCaption).foregroundStyle(Theme.inkDim)
                    }
                    Spacer(minLength: 8)
                    Button { playVoiceover() } label: {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 26)).foregroundStyle(Theme.accent)
                    }
                    .accessibilityLabel(Text("Play it back"))
                    Button { clearVoiceover() } label: {
                        Image(systemName: "trash").font(.system(size: 17)).foregroundStyle(Theme.inkDim)
                    }
                    .accessibilityLabel(Text("Delete this voice"))
                }
                Toggle(isOn: $wordCaptionsOn) { captionToggleLabel(vo) }
                    .tint(Theme.accent)
                    .disabled(vo.words.isEmpty)
            }
            .padding(.top, 2)
        }
    }

    private func captionToggleLabel(_ vo: Voiceover) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Show the words on screen")
                .font(.rpBody.weight(.semibold)).foregroundStyle(Theme.ink)
            Text(vo.words.isEmpty
                 ? "This take has no word timings, so captions stay off."
                 : "Your words appear on the video as you say them.")
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
        }
    }

    private func readyDetail(_ vo: Voiceover) -> String {
        let secs = vo.duration > 0 ? timeLabel(vo.duration) : "ready"
        if vo.words.isEmpty { return "\(secs) · no captions" }
        return "\(secs) · \(vo.words.count) caption words"
    }

    private func timeLabel(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: Voiceover actions

    /// Record button: stop+transcribe if already recording, else ask for
    /// permission and start.
    ///
    /// The MICROPHONE is the only thing recording actually needs. Speech
    /// Recognition is asked for at the same time, but it only buys captions —
    /// so a user who has granted the mic and refused (or been restricted from)
    /// Speech Recognition still records, and just loses the words on screen.
    /// Blocking the whole feature on it, as this did, threw away a recording
    /// nobody had a reason to lose.
    private func recordTapped() {
        if recorder.isRecording { stopAndTranscribe(); return }
        guard narrationPreparationMessage == nil else { return }
        voiceError = nil
        voiceNote = nil
        speechDenied = false
        let permissionID = UUID()
        voicePermissionID = permissionID
        requestingVoicePermission = true
        Task { @MainActor in
            defer {
                if voicePermissionID == permissionID {
                    voicePermissionID = nil; requestingVoicePermission = false
                }
            }
            // `requestPermissions()` is mic AND speech; it prompts for both.
            let both = await recorder.requestPermissions()
            guard voicePermissionID == permissionID, work.isPresented, phase == .setup, voiceMode == .myVoice,
                  work.isContextCurrent else { return }
            let micOK = both || recorder.hasMicrophonePermission
            guard micOK else {
                voiceError = "Rendprop needs the microphone to record your voice. Turn it on in Settings → Rendprop → Microphone."
                return
            }
            // Mic yes, speech no: record anyway, captions off, say so once.
            if !both {
                speechDenied = true
                voiceNote = Self.captionsOffNote
            }
            beginTake()
        }
    }

    /// The one line shown when the recording will have no captions because
    /// Speech Recognition is off. Same words wherever that happens.
    private static let captionsOffNote =
        "Captions are off — Speech Recognition is turned off in Settings."

    /// Clear the last take and start a new one. Main-actor only.
    private func beginTake() {
        musicPreview.stop()
        voPlayer?.pause(); voPlayer = nil
        voiceover = nil
        do {
            try recorder.start()
            Haptics.selection()
        } catch {
            voiceError = error.localizedDescription
        }
    }

    /// Stop the take, transcribe on-device, persist the audio, build the
    /// Voiceover. Transcription is SKIPPED entirely when Speech Recognition
    /// can't run (denied, restricted, or no recogniser) — the take is still
    /// kept, with `words: []`, and captions simply don't render. A failure
    /// during transcription is equally non-fatal.
    private func stopAndTranscribe() {
        guard recorder.isRecording, !isTranscribing else { return }
        isTranscribing = true
        voiceError = nil
        voiceNote = nil
        let listingID = listing.id.uuidString
        // Snapshotted on the main actor, before the Task.
        let deniedAtRecord = speechDenied
        Task {
            do {
                let url = try await recorder.stop()
                let dur = await MainActor.run { recorder.elapsed }
                var text = ""
                var words: [CaptionWord] = []
                // Authorised with a working recogniser, or not yet asked (the
                // transcriber does its own asking). Anything else: don't try.
                let canTranscribe = !deniedAtRecord
                    && (SpeechTranscriber.isAvailable() || SpeechTranscriber.canAskForPermission())
                if canTranscribe {
                    do {
                        let r = try await SpeechTranscriber.transcribe(url)
                        text = r.text
                        words = r.words
                    } catch {
                        // Captions unavailable, audio still good — TranscribeError's
                        // own copy already says "the voiceover still records".
                        let note = error.localizedDescription
                        await MainActor.run { voiceNote = note }
                    }
                } else {
                    let note = deniedAtRecord
                        ? Self.captionsOffNote
                        : "Captions are off — speech recognition isn't available on this phone right now."
                    await MainActor.run { voiceNote = note }
                }
                let persisted = await Task.detached {
                    Voiceover.persistAudio(from: url, listingID: listingID)
                }.value
                let vo = Voiceover(audioURL: persisted, duration: dur, transcript: text,
                                   words: words, source: .myVoice, voiceName: nil)
                await MainActor.run {
                    voiceover = vo
                    voPlayer = nil
                    isTranscribing = false
                    Haptics.success()
                    Analytics.track("voiceover_added", ["ok": "true", "duration_s": String(Int(dur))])
                }
            } catch {
                let message = error.localizedDescription
                await MainActor.run {
                    isTranscribing = false
                    voiceError = message
                }
            }
        }
    }

    /// Load the ElevenLabs voice catalogue. A 503 (no key configured) surfaces
    /// the server's "needs setting up" message rather than an empty picker.
    /// Waits for an anonymous session; network recovery never asks to register.
    private func loadVoices() {
        guard !loadingVoices, aiVoices.isEmpty else { return }
        connection.run { loadVoicesWithSession() }
    }

    private func loadVoicesWithSession() {
        guard !loadingVoices, aiVoices.isEmpty else { return }
        loadingVoices = true
        voiceError = nil
        let api = model.api                       // snapshot on the main actor
        Task {
            do {
                let list = try await api.aiVoices()
                await MainActor.run {
                    aiVoices = list
                    if selectedVoiceID.isEmpty { selectedVoiceID = list.first?.voiceID ?? "" }
                    loadingVoices = false
                }
            } catch {
                let message = AIFailure(error).message
                await MainActor.run {
                    loadingVoices = false
                    voiceError = message
                }
            }
        }
    }

    // MARK: "Write my script"

    /// Write the reel's script from this listing's own data — no questions
    /// asked. Everything it needs is already on the listing (beds, baths, sqft,
    /// price, tagline, the industry detail fields, the city/state) and on the
    /// reel itself (how many photos, which areas, how long it runs).
    ///
    /// NEVER CLOBBERS WORDS THAT ARE ALREADY THERE. The field can be holding
    /// the transcript of a recording the agent actually made — `onChange(of:
    /// voiceMode)` seeds `aiScript` from `voiceover?.transcript` when they
    /// switch to AI voice — and quietly replacing THAT with a machine's version
    /// throws away the one thing no button can redo. A non-empty field asks.
    private func writeScript() {
        guard !scriptInFlight else { return }
        guard aiScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showScriptReplaceConfirm = true
            return
        }
        runScriptWriter()
    }

    /// The call itself waits for an anonymous session; one call per
    /// tap; the result lands in the EDITABLE field, never in a modal — the whole
    /// point is that the agent fixes the two words the model got wrong.
    private func runScriptWriter() {
        guard !scriptInFlight else { return }
        connection.run { authorizeVideoPreparation { runScriptWriterWithSession() } }
    }

    private func runScriptWriterWithSession() {
        guard !scriptInFlight else { return }
        do { try requirePreparedProcessor() } catch { voiceError = error.localizedDescription; return }
        scriptInFlight = true
        voiceError = nil
        voiceNote = nil
        Haptics.selection()

        // Everything the request needs is read HERE, on the main actor, into
        // plain Sendable values. The Task below never reaches back into the
        // model or the view for anything.
        let permission = preparedProcessorPermission, permissionContext = preparedProcessorContext
        let baseEpoch = AIConsent.shared.revocationRevision, processorEpoch = processorConsent.revision
        let sessionEpoch = auth.syncSessionRevision
        let api = model.api
        let live = model.listings.first(where: { $0.id == listing.id }) ?? listing
        let request = Self.scriptRequest(for: live, space: space,
                                         roomTags: model.assets[listing.id]?.roomTags ?? [],
                                         photoCount: totalSelected,
                                         targetSeconds: targetSeconds,
                                         tone: tone.rawValue)
        let address = live.address
        let noun = space.spaceNoun
        let listingID = listing.id
        let isSample = listing.isSample
        let spaceRaw = space.rawValue
        let toneRaw = tone.rawValue
        let target = targetSeconds

        Task {
            do {
                // Scopes the server's fair-housing gate to THIS listing's real
                // space type (COPY-ASSIST-CONTRACT §5). Resolved exactly the way
                // `generateAIVoice` resolves it one tap later in this same
                // flow, so this adds no side effect the voiceover path doesn't
                // already have.
                try requireProcessorPreparation(permission, context: permissionContext, baseEpoch: baseEpoch, processorEpoch: processorEpoch, sessionEpoch: sessionEpoch)
                var req = request
                // Only ever an UPGRADE on what `scriptRequest` already read off
                // the listing: a nil answer here (offline, signed out, listing
                // gone) must not throw away an id we already knew.
                if !isSample, let resolved = await model.serverListingIDForCompliance(listingID) {
                    req.listingServerID = resolved
                }
                try requireProcessorPreparation(permission, context: permissionContext, baseEpoch: baseEpoch, processorEpoch: processorEpoch, sessionEpoch: sessionEpoch)
                let result = try await api.aiCopyScript(req)
                let filled = Self.filledAddress(result.script, address: address,
                                                fallbackNoun: noun)
                await MainActor.run {
                    aiScript = filled
                    scriptInFlight = false
                    Haptics.success()
                    // A length, two enums and a count. No script text, no
                    // address, no listing id — see the header on Analytics.swift.
                    Analytics.track("ai_script_written",
                                    ["space_type": spaceRaw, "tone": toneRaw,
                                     "chars": String(filled.count),
                                     "target_s": String(target), "ok": "true"])
                }
            } catch {
                // A fair-housing refusal (400 unsupported_edit) fails
                // identically every time, so this is shown and never retried —
                // the same rule the TTS call already follows.
                let message = AIFailure(error).message
                await MainActor.run {
                    scriptInFlight = false
                    voiceError = message
                    // No reason prop: the server's message is written for a
                    // person and can quote the listing's own words back.
                    Analytics.track("ai_script_written",
                                    ["space_type": spaceRaw, "tone": toneRaw,
                                     "target_s": String(target), "ok": "false"])
                }
            }
        }
    }

    /// Build the wire request from the listing.
    ///
    /// THE STREET ADDRESS IS NOT IN HERE AND MUST NEVER BE. `AICopyFacts` has
    /// no field that could carry one — only `region` (city/state), which is
    /// exactly the line the aerial path already sends for scenery context. The
    /// model is told it is writing about a three-bed home in Charlotte, NC; it
    /// is never told which one. The name goes back in on this device, in
    /// `filledAddress`.
    ///
    /// `nonisolated` and pure: it takes value types and returns a value type.
    nonisolated private static func scriptRequest(for listing: Listing, space: SpaceType,
                                                  roomTags: [RoomTag], photoCount: Int,
                                                  targetSeconds: Int, tone: String) -> AIScriptRequest {
        var facts = AICopyFacts()
        // Real estate is the only type with beds/baths/sqft/price; the rest are
        // data-driven from `detailFields` (SpaceType.showsPropertyDetails).
        if space.showsPropertyDetails {
            if listing.beds > 0 { facts.beds = listing.beds }
            if listing.baths > 0 { facts.baths = listing.baths }
            if listing.sqft > 0 { facts.sqft = listing.sqft }
            if listing.price.cents > 0 { facts.priceLabel = listing.price.formatted }
        }
        if let tagline = listing.tagline?.trimmingCharacters(in: .whitespacesAndNewlines),
           !tagline.isEmpty {
            facts.tagline = tagline
        }
        if let region = listing.regionLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
           !region.isEmpty {
            facts.region = region
        }
        // The industry fields the owner actually filled in — a venue's capacity,
        // a restaurant's cuisine, a gym's trial offer. URL fields are skipped:
        // a booking link is for tapping, not for reading aloud.
        var details: [String: String] = [:]
        for field in space.detailFields where !field.isURL {
            let value = listing.detail(field.key).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            details[field.key] = value
        }
        facts.details = details

        // WALK ORDER — the order the areas were tagged during the walkthrough,
        // which is the order a viewer meets them in. Sorted by timestamp because
        // a tag added later can be for an earlier moment.
        let tags = roomTags
            .sorted { $0.tMs < $1.tMs }
            .map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return AIScriptRequest(
            // Attribution only, and only when the listing ALREADY has a server
            // row: this route writes no provenance (there is no media to
            // disclose), so it is not worth a round-trip to create one.
            listingServerID: listing.isSample ? nil : listing.serverID,
            spaceType: space.rawValue,
            facts: facts,
            roomTags: tags,
            photoCount: photoCount,
            targetSeconds: targetSeconds,
            tone: tone)
    }

    /// THE ONE PLACE the address goes back into a script.
    ///
    /// The server writes the literal `{address}` where the property should be
    /// named and never learns what that is — the request carries `region`
    /// ("Charlotte, NC") and nothing finer. Substituting here, on the device, is
    /// what lets the voice say a real address out loud while the address itself
    /// never reaches a third-party model or its request logs. It lives in one
    /// function so there is exactly one line to audit.
    ///
    /// With no address to substitute the contract's rule is to DROP the sentence
    /// the token is in rather than speak a placeholder — "Welcome to this one"
    /// is worse than starting on the second sentence, and leaving "{address}"
    /// in place makes the voice read three literal words out loud. Only if
    /// dropping would leave nothing at all does the token collapse into the
    /// neutral phrase this screen already uses elsewhere ("this home").
    nonisolated private static func filledAddress(_ script: String, address: String,
                                                  fallbackNoun: String) -> String {
        // The exact token the server writes where the property should be named
        // (COPY-ASSIST-CONTRACT §5). ONE file-scope constant, so the places that
        // look for it can never disagree about what they are looking for.
        let token = addressToken
        guard script.contains(token) else { return script }
        let name = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            return script.replacingOccurrences(of: token, with: name)
        }
        let kept = sentences(of: script)
            .filter { !$0.contains(token) }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !kept.isEmpty { return kept }
        return script.replacingOccurrences(of: token, with: "this \(fallbackNoun)")
    }

    /// Split a script into sentences.
    ///
    /// Deliberately simple. This text was written moments ago by the copy model
    /// as short marketing sentences — not prose full of abbreviations — and the
    /// split is only ever used to drop a sentence from a script the agent is
    /// about to edit by hand anyway. A wrong split costs one sentence too many
    /// or too few in an editable box, never a wrong address.
    nonisolated private static func sentences(of text: String) -> [String] {
        let marked = text
            .replacingOccurrences(of: ". ", with: ".\u{1}")
            .replacingOccurrences(of: "! ", with: "!\u{1}")
            .replacingOccurrences(of: "? ", with: "?\u{1}")
        return marked.components(separatedBy: "\u{1}")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Speak the script with ElevenLabs, download the audio, build the Voiceover.
    /// Spends money, so: session awaited, one call per tap (`ttsInFlight`), one
    /// idempotency key per tap, NEVER auto-retried — a fair-housing refusal (400)
    /// would fail identically, so the server's message is shown to re-word.
    private func generateAIVoice() {
        guard !ttsInFlight else { return }
        connection.run { authorizeVideoPreparation { generateAIVoiceWithSession() } }
    }

    private func generateAIVoiceWithSession() {
        guard !ttsInFlight else { return }
        do { try requirePreparedProcessor() } catch { voiceError = error.localizedDescription; return }
        let script = aiScript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard script.count >= 2 else { voiceError = "Type a short script first."; return }
        let voiceID = selectedVoiceID
        guard !voiceID.isEmpty else { voiceError = "Pick a voice first."; return }
        let api = model.api                       // snapshot on the main actor
        let listingID = listing.id
        let isSample = listing.isSample
        let key = UUID().uuidString               // one idempotency key per tap
        let actor = auth.userID, epoch = auth.syncSessionRevision
        let permission = preparedProcessorPermission, permissionContext = preparedProcessorContext
        let baseEpoch = AIConsent.shared.revocationRevision, processorEpoch = processorConsent.revision
        let sessionEpoch = epoch
        let activityScope = NativeActivityStore.currentScope, activityStartedAt = Date()
        NativeActivityStore.shared.observe(id: "voice:\(key)", listingID: listingID, kind: .voice, state: .working,
            stage: "Generating voiceover", startedAt: activityStartedAt, scope: activityScope)
        ttsInFlight = true
        voiceError = nil
        voiceNote = nil
        Task {
            do {
                let serverID: UUID? = isSample ? nil
                    : await model.serverListingIDForCompliance(listingID)
                guard auth.userID == actor, auth.syncSessionRevision == epoch else { throw CloudSyncError.identityChanged }
                try requireProcessorPreparation(permission, context: permissionContext, baseEpoch: baseEpoch, processorEpoch: processorEpoch, sessionEpoch: sessionEpoch)
                let result = try await api.aiVoiceTTS(text: script, voiceID: voiceID,
                                                      listingServerID: serverID,
                                                      label: "Reel voiceover",
                                                      idempotencyKey: key)
                guard auth.userID == actor, auth.syncSessionRevision == epoch else { throw CloudSyncError.identityChanged }
                let persisted = try await Self.downloadVoiceover(from: result.audioURL,
                                                                 listingID: listingID.uuidString)
                guard auth.userID == actor, auth.syncSessionRevision == epoch else { throw CloudSyncError.identityChanged }
                let reference: SharedVoiceReference? = result.sharedResultID.flatMap { resultID in
                    guard let serverID, let ownerID = actor.flatMap(UUID.init(uuidString:)), auth.isIdentified else { return nil }
                    return SharedVoiceReference(resultID: resultID, ownerID: ownerID, listingID: serverID)
                }
                let vo = Voiceover(audioURL: persisted, duration: result.durationS,
                                   transcript: script, words: result.words,
                                   source: .aiVoice, voiceName: result.voiceName, sharedReference: reference)
                await MainActor.run {
                    guard auth.userID == actor, auth.syncSessionRevision == epoch else { return }
                    if reference != nil { try? CloudVoiceStore.saveGeneratedVoice(vo, listingID: listingID) }
                    NativeActivityStore.shared.observe(id: "voice:\(key)", listingID: listingID, kind: .voice, state: .ready,
                        stage: "Voiceover saved", startedAt: activityStartedAt, scope: activityScope)
                    voiceover = vo
                    voPlayer = nil
                    ttsInFlight = false
                    Haptics.success()
                    Analytics.track("voiceover_added", ["ok": "true", "duration_s": String(Int(result.durationS))])
                }
            } catch {
                let message = AIFailure(error).message
                await MainActor.run {
                    ttsInFlight = false
                    if auth.userID == actor, auth.syncSessionRevision == epoch {
                        voiceError = message
                        NativeActivityStore.shared.observe(id: "voice:\(key)", listingID: listingID, kind: .voice, state: .failed,
                            stage: "Voiceover needs checking", startedAt: activityStartedAt, scope: activityScope)
                    }
                }
            }
        }
    }

    /// Download the signed TTS audio into `Documents/Voiceovers/`. The signed URL
    /// is short-lived, so this runs immediately after the TTS call. Off the main
    /// actor (nonisolated static).
    ///
    /// RETRIED up to 3 times with a short backoff. By the time we get here the
    /// server has already spoken the script AND charged the quota — a single
    /// dropped connection used to discard audio the agent had paid for, with an
    /// error that invited them to spend another one. Every failure mode is
    /// retried (a signed R2 GET can 404 for a moment right after the upload),
    /// and if all three attempts fail the message says plainly that the audio
    /// was made and counted, so nobody re-generates blindly.
    nonisolated private static func downloadVoiceover(from url: URL, listingID: String) async throws -> URL {
        var lastReason = "the download didn't finish"
        for attempt in 0..<3 {
            if attempt > 0 {
                // 0.6 s, then 1.2 s.
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 600_000_000)
            }
            if Task.isCancelled { throw CancellationError() }
            do {
                let (tmp, resp) = try await URLSession.shared.download(from: url)
                if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    lastReason = "the server answered HTTP \(http.statusCode)"
                    try? FileManager.default.removeItem(at: tmp)
                    continue
                }
                // ElevenLabs returns mpeg; give the temp file an extension that
                // persistAudio carries through to the final <listing>-<stamp>.mp3.
                let named = tmp.deletingLastPathComponent()
                    .appendingPathComponent("vo-\(UUID().uuidString).mp3")
                try? FileManager.default.removeItem(at: named)
                try FileManager.default.moveItem(at: tmp, to: named)
                return Voiceover.persistAudio(from: named, listingID: listingID)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                lastReason = error.localizedDescription
            }
        }
        throw AIImagePrep.error(
            "Your voiceover was made and it has already been counted against your plan, "
            + "but it couldn't be downloaded — \(lastReason). Check your connection. "
            + "Tapping Make the voice again will use another one.")
    }

    private func playVoiceover() {
        guard let vo = voiceover else { return }
        musicPreview.stop()
        voPlayer?.pause()
        let p = AVPlayer(url: vo.audioURL)
        voPlayer = p
        p.play()
        Haptics.selection()
    }

    private func clearVoiceover() {
        voPlayer?.pause()
        voPlayer = nil
        voiceover = nil
        voiceNote = nil
        voiceError = nil
        Haptics.selection()
    }

    // MARK: Selection

    nonisolated private static func selectionPreservingOrder(_ selected: [String], photos: [EnhancedPhoto],
                                                           index: PhotoVersionHistory.Index? = nil) -> [String] {
        let available = Set(photos.map(\.id))
        var seen = Set<String>()
        // Explicit versions never become another staged/decluttered/original
        // version merely because that family's publication choice changed.
        return selected.filter { available.contains($0) && seen.insert($0).inserted }
    }

    private func selectThumb(_ p: EnhancedPhoto) -> some View {
        let order = selected.firstIndex(of: p.id)
        let reviewed = (try? PhotoVersionHistory.requireReelReview(imageURL: p.enhancedURL)) != nil
        return Button { toggle(p) } label: {
            ZStack(alignment: .topTrailing) {
                DetailPhotoThumb(url: p.enhancedURL, height: 100)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(order != nil ? Theme.accent : Theme.border,
                                          lineWidth: order != nil ? 2 : 1)
                    )
                    .opacity(!reviewed || order == nil && selected.count >= VideoSelectionCapacity.maximumPhotos ? 0.4 : 1)

                if !reviewed {
                    Text("Review photo first").font(.caption2.weight(.semibold))
                        .padding(5).background(.ultraThinMaterial, in: Capsule())
                } else if let order {
                    Text("\(order + 1)")
                        .font(.caption2.weight(.bold))
                        .frame(width: 22, height: 22)
                        .background(Theme.accent, in: Circle())
                        .foregroundStyle(Color.white)
                        .padding(5)
                } else {
                    Image(systemName: "circle")
                        .font(.system(size: 17))
                        .foregroundStyle(Color.white.opacity(0.9))
                        .shadow(radius: 2)
                        .padding(7)
                }
            }
        }
        .buttonStyle(ScalePressStyle())
        .disabled(!reviewed)
        .accessibilityLabel(Text(!reviewed ? "Photo needs review in Photo Studio before use in a reel." : order.map { "Photo in reel — position \($0 + 1). Tap to remove." }
                                 ?? "Photo not in reel. Tap to add."))
        .accessibilityIdentifier("reel.photo.\(p.id)")
    }

    private func toggle(_ p: EnhancedPhoto) {
        if let idx = selected.firstIndex(of: p.id) {
            selected.remove(at: idx)
        } else if selected.count < VideoSelectionCapacity.maximumPhotos {
            guard (try? PhotoVersionHistory.requireReelReview(imageURL: p.enhancedURL)) != nil else { return }
            selected.append(p.id)
            Haptics.selection()
        }
    }

    private func cancelWork() {
        if work.serverJob != nil {
            Task { await PropertyVideoJobRunner.shared.cancel(work) }
            return
        }
        let task = workTask
        work.cancel()
        resetToSetup()
        // The cancelled task parks its already-billed clips in its own `catch`,
        // which has not run yet at this instant — so wait for it before reading
        // them back. Without this the "Unfinished reel" card would be built one
        // frame too early and show nothing, and the whole point of cancelling
        // safely is that the agent SEES the clips he paid for (the 4,000 sq ft
        // field test).
        guard !listing.isSample else { return }
        let listingID = listing.id
        Task {
            if let task = task { await task.value }
            parkedClips = PendingReelClips.load(for: listingID)
        }
    }

    private func resetToSetup() {
        if let saved = work.serverJob {
            guard saved.mayReplaceAfterResolution else {
                phase = .generating; PropertyVideoJobRunner.shared.checkNow(work); return
            }
            // Only the completed server-owned recipe is retired. Existing
            // legacy local clip requests use their unchanged recovery flow.
            if saved.wasRefusedBeforeAdmission {
                guard pendingRequest == nil, pendingBatch?.completedPaths.isEmpty != false else { return }
            }
            guard PropertyVideoJobRunner.shared.retireResolvedPresentation(work, saved: saved, model: model) else { return }
            // Reopening a terminal job from the global banner starts with no
            // sheet-local selection. Keep its exact available saved versions
            // and order; never substitute originals or overwrite a new choice.
            if selected.isEmpty {
                let available = Set(reelPhotos.map(\.id))
                selected = saved.request.sources.map { saved.request.isPhotoMotion ? $0.photoID : $0.photoVersionID }.filter { available.contains($0) }
            }
            if saved.request.isPhotoMotion {
                photoMotion = true
                restorePhotoMotionTimings(saved.request)
            }
            photoMotionProfile = .current
            photoMotionDirection = .pushIn
            pendingBatch?.clear(); pendingBatch = nil; work.serverJob = nil
        }
        player?.pause()
        player = nil
        reelURL = nil
        savedToPhotos = false
        saveError = nil
        failure = nil
        completedClips = 0
        originalPhotoMotionShots = 0
        totalClips = 0
        clipIssues = []
        phase = .setup
        lastReel = Self.newestReel(for: listing.id)   // the one just made is now "your last reel"
        // A run that failed part-way parked its billed clips — surface them again
        // rather than letting "Try again" charge for the same clips twice.
        parkedClips = listing.isSample ? nil : PendingReelClips.load(for: listing.id)
        reloadPendingRequest()
        if pendingRequest == nil && pendingBatch == nil && parkedClips == nil &&
            unreadablePendingContext == nil && !unreadableBatch {
            work.configuration = nil
        }
        videoPurpose = nil
        restoreVideoPurposeForSavedWork()
    }

    private func reloadPendingRequest() {
        guard !listing.isSample, let owner = auth.userID,
              let live = model.listings.first(where: { $0.id == listing.id }), live.cloudUnavailable != true else {
            pendingRequest = nil; unreadablePendingContext = nil; pendingBatch = nil; unreadableBatch = false; recoveredRetryRequestID = nil; return
        }
        let context = PendingReelRequest.Context(listingID: live.id, serverListingID: live.serverID,
            owner: owner, workspace: WorkspaceContext.selectedOrgID)
        pendingRequest = PendingReelRequest.load(context)
        unreadablePendingContext = pendingRequest == nil && PendingReelRequest.exists(context) ? context : nil
        do { pendingBatch = try PendingReelBatch.load(context); scenePlanningNotice = pendingBatch?.scenePlanningNotice; unreadableBatch = false }
        catch { pendingBatch = nil; unreadableBatch = true }
        if recoveredRetryRequestID != pendingRequest?.job.requestId { recoveredRetryRequestID = nil }
    }

    @ViewBuilder private var pendingRequestCard: some View {
        if unreadableBatch {
            Text("Saved video progress cannot be read. Your requests and clips are kept; new generation is paused until that progress can be recovered.")
                .font(.rpCaption).foregroundStyle(Theme.warn)
        }
        if let batch = pendingBatch, pendingRequest == nil, unreadablePendingContext == nil {
            VStack(alignment: .leading, spacing: 10) {
                Text("Saved video: \(batch.completedPaths.count) of \(batch.photos.count) photos finished")
                    .font(.rpBody.weight(.semibold))
                Text("Continue uses the saved photo order, keeps finished clips and generates only the remaining photos. You can finish a shorter video from saved clips instead.")
                    .font(.rpCaption).foregroundStyle(Theme.inkDim)
                Button(batch.completedPaths.count == batch.photos.count ? "Finish saved full video" : "Continue saved video") {
                    connection.run { continueSavedBatch(batch) }
                }.disabled(isWorking).accessibilityIdentifier("reel.continue-saved-batch")
                Button("Discard saved batch…", role: .destructive) { showDiscardParkedConfirm = true }.disabled(isWorking)
            }.frame(maxWidth: .infinity, alignment: .leading).card()
        }
        if let request = pendingRequest {
            VStack(alignment: .leading, spacing: 10) {
                Label(request.submissionUnconfirmed == true ? "Photo \(request.photoNumber) submission needs review" : "Photo \(request.photoNumber) has a saved video request", systemImage: "clock.arrow.circlepath")
                    .font(.rpBody.weight(.semibold))
                if request.submissionUnconfirmed == true {
                    Text("The submission ended without a usable receipt. It may already count a clip. There is no automatic retry or result lookup. Review your usage before forgetting this request; generating again may count another clip.")
                        .font(.rpCaption).foregroundStyle(Theme.inkDim)
                } else {
                    Text("Check this existing request before generating again. Recovery checks its status, downloads its clip and checks it against the saved source photo; it sends no new generation. Remote results can expire.")
                        .font(.rpCaption).foregroundStyle(Theme.inkDim)
                    if recoveredRetryRequestID == request.job.requestId, request.qualityAttempt == 0 {
                        Text("The first AI clip changed the property. Nothing is generating now. A safer retry sends this same photo once more; still photo happens on this iPhone without another AI generation.")
                            .font(.rpCaption).foregroundStyle(Theme.inkDim)
                        Button("Retry once with safer motion") { connection.run { resolveRecoveredRetry(request, choice: .saferRetry) } }
                            .disabled(isWorking).accessibilityIdentifier("reel.retry-saved-safer")
                        Button("Use still photo") { connection.run { resolveRecoveredRetry(request, choice: .originalPhoto) } }
                            .disabled(isWorking).accessibilityIdentifier("reel.use-saved-original")
                    } else {
                        Button("Recover saved request") { connection.run { recoverPendingRequest(request) } }
                            .disabled(isWorking).accessibilityIdentifier("reel.recover-request")
                    }
                }
                Button("Forget request…") { showDiscardPendingConfirm = true }.disabled(isWorking)
            }.frame(maxWidth: .infinity, alignment: .leading).card()
        } else if let context = unreadablePendingContext {
            VStack(alignment: .leading, spacing: 10) {
                Text("An earlier video request cannot be read").font(.rpBody.weight(.semibold))
                if PendingReelRequest.hasUnreadableAdoptionMetadata(context) {
                    Text("Saved account-transfer records could not be read. Choose your workspace and review its saved request there, or get recovery help. Your saved records have been kept and no new clip will be submitted.").font(.rpCaption)
                } else {
                    Text("Generating is paused because that request may already count a clip. Review your usage before deliberately forgetting it.").font(.rpCaption)
                    Button("Forget request…") { showDiscardPendingConfirm = true }.disabled(isWorking)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).card()
        }
    }

    private func snapshotReelConfiguration() -> ReelWorkJob.Configuration {
        ReelWorkJob.Configuration(extras: selectedExtras.filter { FileManager.default.fileExists(atPath: $0.path) },
            captions: VideoBrandingPolicy.titleCard(captionsOn ? Self.reelCaptions(for: listing) : nil, aspect: portrait ? "9:16" : "16:9"),
            voice: voiceMode == .off ? nil : voiceover,
            captionStyle: voiceMode != .off && wordCaptionsOn ? .standard : .off,
            shotStyle: bigCaptionsOn ? bigCaptionStyle : .off, transition: reelTransition,
            aspect: portrait ? "9:16" : "16:9")
    }

    /// Called only for this job's OS-expiration pause. Terminal QC, quota, auth
    /// or network errors never trigger this automatic continuation.
    private func resumePausedWork() {
        guard work.isContextCurrent, !work.running else { return }
        reloadPendingRequest()
        if let request = pendingRequest, request.submissionUnconfirmed != true {
            recoverPendingRequest(request, resumeBatch: true)
        } else if pendingRequest == nil, unreadablePendingContext == nil, !unreadableBatch, let batch = pendingBatch {
            continueSavedBatch(batch)
        } else {
            phase = .setup
        }
    }

    private var pausedSection: some View {
        VStack(spacing: 12) {
            Text("Your video is safely paused").font(.rpHeadline)
            Text("iPhone paused background work. Finished clips and the current request are kept. Open this listing’s Make a video tool to recover and continue; it will not finish while the app is paused.")
                .font(.rpCaption).foregroundStyle(Theme.inkDim).multilineTextAlignment(.center)
            Button("Continue saved video") { work.resumeForeground() }.disabled(work.running)
            Button("Stop for now", role: .destructive) { cancelWork() }
        }.frame(maxWidth: .infinity).padding(.vertical, 24)
    }

    private func recoverPendingRequest(_ request: PendingReelRequest, resumeBatch: Bool = false) {
        let model = self.model, auth = self.auth
        do { try Self.requireSavedReelReview(try PendingReelBatch.load(request.context)) }
        catch { failure = AIFailure(error, title: "Review the saved photo first"); return }
        guard !isWorking, request.submissionUnconfirmed != true,
              pendingRequest?.job.requestId == request.job.requestId else { return }
        let api = model.api, revision = auth.syncSessionRevision, consent = AIConsent.shared.revocationRevision
        let validate: @MainActor @Sendable () throws -> Void = {
            try Task.checkCancellation()
            guard AIConsent.shared.isGranted, AIConsent.shared.revocationRevision == consent,
                  auth.userID == request.context.owner, auth.syncSessionRevision == revision,
                  WorkspaceContext.selectedOrgID == request.context.workspace,
                  let current = model.listings.first(where: { $0.id == request.context.listingID }),
                  current.cloudUnavailable != true, current.serverID == request.context.serverListingID else {
                throw CancellationError()
            }
        }
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("reel-recovery-\(UUID())", isDirectory: true)
        phase = .generating; completedClips = 0; totalClips = 1
        statusText = "Checking saved request for photo \(request.photoNumber)…"
        failure = nil; clipIssues = []; recoveredRetryRequestID = nil
        if work.configuration == nil { work.configuration = snapshotReelConfiguration() }
        work.start(identityIsCurrent: { [model, id = listing.id] in model.listings.contains { $0.id == id && $0.cloudUnavailable != true } }, resume: { resumePausedWork() }) {
            do {
                try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
                let clip = try await Self.retrieveClip(job: request.job, pending: request, api: api,
                    into: tmpDir, index: request.photoNumber - 1, clearReceiptOnDownload: false, requireCurrent: validate)
                try validate()
                _ = try await Self.acknowledgeRecoveredClip(clip, request: request, requireCurrent: validate)
                try? FileManager.default.removeItem(at: tmpDir)
                parkedClips = PendingReelClips.load(for: request.context.listingID)
                reloadPendingRequest(); phase = .setup
                if resumeBatch, let saved = pendingBatch {
                    work.afterCurrentOperation { continueSavedBatch(saved) }
                }
            } catch {
                try? FileManager.default.removeItem(at: tmpDir)
                reloadPendingRequest()
                if error is CancellationError || Task.isCancelled { return }
                if let refusal = error as? ReelQualityRefusal, refusal.mayRetry, request.qualityAttempt == 0 {
                    recoveredRetryRequestID = request.job.requestId
                }
                clipIssues = [ReelClipIssue(photoNumber: request.photoNumber, error: error)]
                failure = ReelClipIssue.failure(for: error, title: "Couldn't recover the clip")
                phase = .failed
            }
        }
    }

    /// Both choices are explicit. Recovery itself remains an existing-job lookup.
    private func resolveRecoveredRetry(_ request: PendingReelRequest, choice: ReelRecoveryChoice) {
        let model = self.model, auth = self.auth
        guard !isWorking, recoveredRetryRequestID == request.job.requestId, request.qualityAttempt == 0,
              pendingRequest?.job.requestId == request.job.requestId else { return }
        let api = model.api, revision = auth.syncSessionRevision, consent = AIConsent.shared.revocationRevision
        let validate: @MainActor @Sendable () throws -> Void = {
            try Task.checkCancellation()
            guard AIConsent.shared.isGranted, AIConsent.shared.revocationRevision == consent,
                  auth.userID == request.context.owner, auth.syncSessionRevision == revision,
                  WorkspaceContext.selectedOrgID == request.context.workspace,
                  let current = model.listings.first(where: { $0.id == request.context.listingID }),
                  current.cloudUnavailable != true, current.serverID == request.context.serverListingID else { throw CancellationError() }
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("reel-choice-\(UUID())", isDirectory: true)
        failure = nil; clipIssues = []; phase = .generating
        statusText = choice == .saferRetry ? "Photo \(request.photoNumber) — one safer retry…" : "Photo \(request.photoNumber) — using still photo…"
        if work.configuration == nil { work.configuration = snapshotReelConfiguration() }
        work.start(identityIsCurrent: { [model, id = listing.id] in model.listings.contains { $0.id == id && $0.cloudUnavailable != true } }, resume: { resumePausedWork() }) {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                _ = try await Self.resolveSavedQualityRetry(request, choice: choice, api: api, into: dir, requireCurrent: validate)
                try validate()
                try? FileManager.default.removeItem(at: dir)
                recoveredRetryRequestID = nil; reloadPendingRequest()
                parkedClips = PendingReelClips.load(for: request.context.listingID)
                phase = .setup
            } catch {
                try? FileManager.default.removeItem(at: dir)
                reloadPendingRequest()
                if error is CancellationError || Task.isCancelled { return }
                if let refusal = error as? ReelQualityRefusal, refusal.mayRetry,
                   pendingRequest?.qualityAttempt == 0 { recoveredRetryRequestID = pendingRequest?.job.requestId }
                failure = ReelClipIssue.failure(for: error, title: "Couldn't finish this photo")
                clipIssues = [ReelClipIssue(photoNumber: request.photoNumber, error: error)]; phase = .failed
            }
        }
    }

    /// Resume only this saved ordered batch. Finished positions come from its
    /// durable progress; selected setup photos cannot reorder or replace it.
    private func continueSavedBatch(_ saved: PendingReelBatch) {
        let model = self.model, auth = self.auth
        do { try Self.requireSavedReelReview(saved) }
        catch { failure = AIFailure(error, title: "Review the saved photo first"); return }
        guard !isWorking, pendingRequest == nil, unreadablePendingContext == nil,
              pendingBatch?.id == saved.id else { return }
        let api = model.api, revision = auth.syncSessionRevision, consent = AIConsent.shared.revocationRevision
        let validate: @MainActor @Sendable () throws -> Void = {
            try Task.checkCancellation()
            guard AIConsent.shared.isGranted, AIConsent.shared.revocationRevision == consent,
                  auth.userID == saved.context.owner, auth.syncSessionRevision == revision,
                  WorkspaceContext.selectedOrgID == saved.context.workspace,
                  let current = model.listings.first(where: { $0.id == saved.context.listingID }),
                  current.cloudUnavailable != true, current.serverID == saved.context.serverListingID else { throw CancellationError() }
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("reel-resume-\(UUID())", isDirectory: true)
        let configuration = work.configuration ?? snapshotReelConfiguration()
        work.configuration = configuration
        let extras = configuration.extras
        let captions = VideoBrandingPolicy.titleCard(configuration.captions, aspect: saved.aspect), voice = configuration.voice
        let captionStyle = configuration.captionStyle, shotStyle = configuration.shotStyle
        let transition = configuration.transition
        phase = .generating; failure = nil; clipIssues = []
        totalClips = saved.photos.count; completedClips = saved.completedPaths.count
        work.start(identityIsCurrent: { [model, id = listing.id] in model.listings.contains { $0.id == id && $0.cloudUnavailable != true } }, resume: { resumePausedWork() }) {
            do {
                try validate()
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let batch = try await Self.completeSavedBatch(saved, api: api, into: dir, requireCurrent: validate,
                    progress: { number in completedClips = number; statusText = "Photo \(number + 1) of \(saved.photos.count) — making video…" })
                try validate()
                phase = .stitching
                let photoClips = batch.completedPaths.map { FileStore.url(fromRelativePath: $0) }
                let reelsDir = FileStore.documents.appendingPathComponent("reels", isDirectory: true)
                try FileManager.default.createDirectory(at: reelsDir, withIntermediateDirectories: true)
                let out = reelsDir.appendingPathComponent("\(saved.context.listingID.uuidString)-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString).mp4")
                try await ReelComposer.compose(shots: Self.shots(extras: extras, photoClips: photoClips,
                    plan: batch.photos.map { $0.shot?.value }, captionsOn: shotStyle.isOn),
                    renderSize: batch.aspect == "9:16" ? CGSize(width: 1080, height: 1920) : CGSize(width: 1920, height: 1080),
                    options: ReelComposer.Options(titleCard: captions, voiceover: voice, captionStyle: captionStyle,
                        shotCaptionStyle: shotStyle, transition: transition), output: out)
                try validate()
                try OriginalPhotoMotion.saveSummary(count: photoClips.filter(OriginalPhotoMotion.isClip).count, for: out)
                let finishedRecord = try await ListingVideoPreparation.retain(output: out, listingID: saved.context.listingID,
                    ownerID: saved.context.owner, workspaceID: saved.context.workspace, serverListingID: saved.context.serverListingID,
                    purpose: batch.aspect == "16:9" ? .listing : .socialMedia, sources: batch.completedSources ?? [],
                    includesOpeningClip: !extras.isEmpty, brandingPolicy: batch.aspect == "16:9" ? "unbranded" : nil)
                try validate()
                if finishedRecord.canSelectForWebsite, model.listings.first(where: { $0.id == saved.context.listingID })?.websiteVideoRelPath == nil {
                    try await model.selectWebsiteVideo(finishedRecord, for: saved.context.listingID, onlyIfUnselected: true)
                    try validate()
                }
                batch.clear()
                PendingReelClips.retire(photoClips, for: saved.context.listingID)
                try? FileManager.default.removeItem(at: dir)
                reloadPendingRequest(); parkedClips = PendingReelClips.load(for: saved.context.listingID)
                reelURL = out; lastReel = out; player = AVPlayer(url: out)
                originalPhotoMotionShots = photoClips.filter(OriginalPhotoMotion.isClip).count
                phase = .done; Haptics.success()
            } catch {
                // All completed shots already have durable progress. The current
                // accepted/unknown receipt stays; no following photo is submitted.
                try? FileManager.default.removeItem(at: dir)
                reloadPendingRequest(); parkedClips = PendingReelClips.load(for: saved.context.listingID)
                if error is CancellationError || Task.isCancelled { return }
                failure = ReelClipIssue.failure(for: error, title: "Couldn't continue the saved reel")
                phase = .failed
            }
        }
    }

    /// Open a reel that already exists on disk — same result screen as a fresh
    /// one (play / Save to Photos / Share), no AI spend. The orientation is
    /// read off the file so the player isn't letterboxed into the wrong frame;
    /// until it loads, the format toggle's current value is used.
    private func openExistingReel(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            lastReel = nil                       // deleted underneath us (e.g. Clear local data)
            return
        }
        player?.pause()
        work.restoreRetainedResult(at: url, originalPhotoCount: OriginalPhotoMotion.summaryCount(for: url))
        player = AVPlayer(url: url)
        savedToPhotos = false
        saveError = nil
        failure = nil
        clipIssues = []
        Haptics.selection()
        Task {
            guard let isPortrait = await Self.isPortraitVideo(url) else { return }
            await MainActor.run { portrait = isPortrait }
        }
    }

    /// Match the preview container to the actual encoded display shape, not a
    /// fixed height across the sheet's width. Preferred rotation is included.
    nonisolated private static func reelDisplayAspect(_ url: URL) async -> CGFloat? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform) else { return nil }
        let rect = CGRect(origin: .zero, size: size).applying(transform)
        let width = abs(rect.width), height = abs(rect.height)
        guard width > 0, height > 0, width.isFinite, height.isFinite else { return nil }
        return width / height
    }

    /// True when the video's displayed frame is taller than it is wide. Nil when
    /// the file can't be read — the caller then leaves the toggle alone.
    nonisolated private static func isPortraitVideo(_ url: URL) async -> Bool? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return nil }
        guard let size = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform) else { return nil }
        let rect = CGRect(origin: .zero, size: size).applying(transform)
        let w = abs(rect.width), h = abs(rect.height)
        guard w > 0, h > 0, w.isFinite, h.isFinite else { return nil }
        return h >= w
    }

    /// `Documents/reels/<listingID>-<unix>.mp4`, newest first.
    ///
    /// `fileprivate`, not `private`: the listing screen's FILES section lists
    /// EVERY reel through this same glob rather than growing a second, subtly
    /// different one (`private` on a member is scoped to the type, so
    /// `FlythroughDetailView` could not see it).
    nonisolated fileprivate static func reelFiles(for listingID: UUID) -> [URL] {
        datedReelFiles(for: listingID).map(\.url)
    }

    /// The same glob with each reel's creation date kept.
    ///
    /// Build 8 read that date INSIDE the sort comparator, so sorting n reels cost
    /// O(n log n) stat syscalls, and then the listing screen's FILES scan stat'd
    /// every one of them a second time to build its rows (the build-9 lag
    /// report). One read per file, sorted on the value, used by both.
    nonisolated fileprivate static func datedReelFiles(for listingID: UUID) -> [DatedFile] {
        let dir = FileStore.documents.appendingPathComponent("reels", isDirectory: true)
        let prefix = "\(listingID.uuidString)-".lowercased()
        return DiskScan.newestFirst(DiskScan.entries(of: dir).filter {
            $0.name.lowercased().hasPrefix(prefix) && $0.url.pathExtension.lowercased() == "mp4"
        })
    }

    nonisolated private static func newestReel(for listingID: UUID) -> URL? {
        reelFiles(for: listingID).first
    }

    /// "Made 4 Sep at 2:15 PM" — the file's creation date, or a neutral line
    /// when the filesystem has none.
    nonisolated private static func reelDateLabel(_ url: URL) -> String {
        guard let date = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate else {
            return "Saved on this phone"
        }
        return "Made \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    /// Keep the newest `keeping` reels for a listing and delete the rest — a
    /// reel is ~10–40 MB and nothing else ever removed them (F-A-23). Only ever
    /// called AFTER a new reel has been written, so it can't delete the only copy.
    nonisolated private static func pruneReels(for listingID: UUID, keeping: Int) {
        let files = reelFiles(for: listingID)
        guard files.count > keeping else { return }
        let selected = ListingVideoStore.selected(listingID: listingID, documents: FileStore.documents)?.relativePath
        let pending = (try? ListingVideoStore.pending(listingID: listingID, documents: FileStore.documents))?.relativePath
        for url in files.dropFirst(keeping) {
            let path = FileStore.relativePath(for: url)
            guard path != selected, path != pending else { continue }
            try? FileManager.default.removeItem(at: ListingVideoStore.metadataURL(for: url))
            try? FileManager.default.removeItem(at: url.appendingPathExtension("website-assets.json"))
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: OriginalPhotoMotion.summaryURL(for: url))
        }
    }

    private func saveToPhotos(_ url: URL) {
        guard !isSaving else { return }
        isSaving = true
        saveError = nil
        Task {
            do {
                try await PhotosLibrarySaver.saveVideo(at: url)
                await MainActor.run {
                    isSaving = false
                    savedToPhotos = true
                    Haptics.success()
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    saveError = error.localizedDescription
                }
            }
        }
    }

    /// Disclosure resolution happens before the paid planner, script writer or
    /// voice generator. Only an exact unpublished response selects legacy v1.
    private func authorizeVideoPreparation(_ action: @escaping () -> Void) {
        guard !preparingProcessor else { return }
        preparingProcessor = true
        Task { @MainActor in
            defer { preparingProcessor = false }
            do {
                guard await AIConsent.shared.ensureGranted() else { throw PropertyVideoProcessorFailure.declined }
                let baseEpoch = AIConsent.shared.revocationRevision, processorEpoch = processorConsent.revision
                let sessionEpoch = auth.syncSessionRevision
                if listing.isSample {
                    preparedProcessorContext = nil; preparedProcessorPermission = nil
                } else {
                    guard let actor = auth.userID.flatMap(UUID.init(uuidString:)), auth.isIdentified,
                          let org = WorkspaceContext.selectedOrgID, let api = model.api as? PropertyVideoJobsAPI else {
                        throw PropertyVideoJobStore.Failure.identityChanged
                    }
                    let server = try await requiredVideoCloudListing(actor: actor, org: org, sessionEpoch: sessionEpoch)
                    let context = PropertyVideoJobContext(localListingID: listing.id, listingID: server, actorID: actor, orgID: org)
                    let contract = photoMotion ? nil : (try await api.propertyVideoProcessorContract(context: context))
                    guard context.isCurrent, auth.syncSessionRevision == sessionEpoch, AIConsent.shared.revocationRevision == baseEpoch, processorConsent.revision == processorEpoch else { throw PropertyVideoJobStore.Failure.identityChanged }
                    let permission: PropertyVideoProcessorSnapshot?
                    if let contract { permission = try await processorConsent.ensure(contract, context: context) } else { permission = nil }
                    guard work.isPresented, context.isCurrent, auth.syncSessionRevision == sessionEpoch, AIConsent.shared.revocationRevision == baseEpoch, processorConsent.revision == processorEpoch else { throw PropertyVideoJobStore.Failure.identityChanged }
                    preparedProcessorContext = context; preparedProcessorPermission = permission
                }
                preparedSessionRevision = sessionEpoch; preparedBaseRevision = baseEpoch; preparedProcessorRevision = processorEpoch
                try requirePreparedProcessor()
                action()
            } catch {
                savedPhotoError = error.localizedDescription; voiceError = error.localizedDescription
            }
        }
    }
    /// Video requires a real listing; a best-effort compliance lookup would
    /// discard the create error and incorrectly blame a different account.
    private func requiredVideoCloudListing(actor: UUID, org: UUID, sessionEpoch: UInt64) async throws -> UUID {
        func identityMatches() -> Bool {
            auth.userID.flatMap(UUID.init(uuidString:)) == actor && auth.isIdentified
                && auth.syncSessionRevision == sessionEpoch && WorkspaceContext.selectedOrgID == org
        }
        guard identityMatches(), let current = model.listings.first(where: { $0.id == listing.id && $0.cloudUnavailable != true }),
              model.isInSelectedWorkspace(current) else { throw PropertyVideoJobStore.Failure.identityChanged }
        do {
            let server = try await model.ensureServerListing(current)
            guard identityMatches() else { throw PropertyVideoJobStore.Failure.identityChanged }
            return server
        } catch {
            guard identityMatches() else { throw PropertyVideoJobStore.Failure.identityChanged }
            throw error
        }
    }

    private func requirePreparedProcessor() throws {
        guard let base = preparedBaseRevision, let processor = preparedProcessorRevision, preparedSessionRevision == auth.syncSessionRevision else { throw PropertyVideoProcessorFailure.permissionRequired }
        try requireProcessorPreparation(preparedProcessorPermission, context: preparedProcessorContext, baseEpoch: base, processorEpoch: processor, sessionEpoch: preparedSessionRevision!)
    }
    private func requireProcessorPreparation(_ permission: PropertyVideoProcessorSnapshot?, context: PropertyVideoJobContext?, baseEpoch: UInt64, processorEpoch: UInt64, sessionEpoch: UInt64) throws {
        guard auth.syncSessionRevision == sessionEpoch, AIConsent.shared.isGranted, AIConsent.shared.revocationRevision == baseEpoch, processorConsent.revision == processorEpoch,
              listing.isSample || (context?.isCurrent == true && model.listings.contains(where: { $0.id == listing.id && $0.serverID == context?.listingID && $0.cloudUnavailable != true })) else { throw PropertyVideoJobStore.Failure.identityChanged }
        if let permission, let context { guard processorConsent.permits(permission, context: context) else { throw PropertyVideoProcessorFailure.permissionRequired } }
    }

    /// Private video choices preserve local version/order and the public gallery.
    /// Full masters are uploaded unchanged; only the existing server CPU path resizes them.
    @MainActor private func prepareChosenVideoMasters(_ photos: [EnhancedPhoto], context: PropertyVideoJobContext,
        jobsAPI: any PropertyVideoJobsAPI, requireCurrent: @escaping @MainActor () throws -> Void) async throws -> [PropertyVideoPrivateSourceReply] {
        try await withChosenVideoMasters(photos, context: context, requireCurrent: requireCurrent) { master, orgID, _, check in
            let prepared = try await PropertyVideoPrivateSourceRunner.prepare(master: master, context: context,
                api: jobsAPI, documents: FileStore.documents, requireCurrent: check)
            guard prepared.orgID == orgID else { throw PhotoCloudSelectionFailure.changed }
            return prepared
        }
    }
    @MainActor private func withChosenVideoMasters<Value>(_ photos: [EnhancedPhoto], context: PropertyVideoJobContext,
        maximumMasterBytes: Int = 52_428_800, rawOriginals: Bool = false, requireCurrent: @escaping @MainActor () throws -> Void,
        transform: @MainActor (PropertyVideoChosenMaster, UUID, Bool, @escaping @MainActor () throws -> Void) async throws -> Value) async throws -> [Value] {
        try requireCurrent()
        let projection = try await model.refreshCloudPhotoSelection(listingID: context.localListingID)
        try requireCurrent()
        guard projection.identity.actorID == context.actorID, projection.identity.serverListingID == context.listingID,
              projection.identity.libraryOrgID == context.orgID, !projection.pending,
              let gallery = projection.snapshot.galleryAssetIDs else {
            throw AIImagePrep.error("Save an explicit listing photo selection before uploading private video masters. No listing photos were changed.")
        }
        let cover = projection.snapshot.mainPhotoKey
        let chosenIDs = photos.map(\.id)
        var result: [Value] = []
        for (index, photo) in photos.enumerated() {
            try requireCurrent()
            guard selected == chosenIDs, let version = photo.savedVersion,
                  let fact = projection.versions.first(where: { $0.id == version.id }), fact.historyComplete else { throw PhotoCloudSelectionFailure.changed }
            let measured = try await Task.detached(priority: .utility) { () throws -> (String, Int64, String) in
                let values = try photo.enhancedURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize,
                      size > 0, size <= maximumMasterBytes, let digest = DirectUploader.sha256(of: photo.enhancedURL) else { throw PhotoCloudSelectionFailure.changed }
                let handle = try FileHandle(forReadingFrom: photo.enhancedURL); defer { try? handle.close() }
                let prefix = [UInt8](try handle.read(upToCount: 12) ?? Data())
                let mime: String
                if prefix.starts(with: [255,216,255]) { mime = "image/jpeg" }
                else if prefix.starts(with: [137,80,78,71,13,10,26,10]) { mime = "image/png" }
                else if prefix.count == 12, String(bytes: prefix.prefix(4), encoding: .ascii) == "RIFF", String(bytes: prefix.suffix(4), encoding: .ascii) == "WEBP" { mime = "image/webp" }
                else if let image = CGImageSourceCreateWithURL(photo.enhancedURL as CFURL, nil),
                        let kind = CGImageSourceGetType(image) as String?, ["public.heic", "public.heif"].contains(kind) {
                    mime = kind == "public.heic" ? "image/heic" : "image/heif"
                } else { throw PhotoCloudSelectionFailure.changed }
                return (digest, Int64(size), mime)
            }.value
            try requireCurrent(); try PhotoVersionHistory.requireReelReview(imageURL: photo.enhancedURL)
            guard measured.0 == fact.sha256, measured.1 == fact.bytes, photo.savedVersion == version else { throw PhotoCloudSelectionFailure.changed }
            let originalURL = version.originalFile.map { photo.enhancedURL.deletingLastPathComponent().appendingPathComponent($0) } ?? photo.enhancedURL
            let verifiedOriginal = try PropertyVideoOriginalMaster.isOriginal(version, imageURL: photo.enhancedURL, originalURL: originalURL)
            let rawOriginal = rawOriginals && verifiedOriginal && ["image/jpeg", "image/png", "image/webp"].contains(measured.2)
            var inputURL = photo.enhancedURL, input = measured
            var asset: UUID?
            if rawOriginal {
                statusText = "Saving unchanged video original \(index + 1) of \(photos.count)…"
                asset = try await PropertyVideoOriginalMaster.upload(version: version, imageURL: photo.enhancedURL,
                    originalURL: originalURL, sha256: measured.0, bytes: measured.1, context: context, api: model.api,
                    requireCurrent: requireCurrent)
                try requireCurrent()
            } else {
                asset = projection.assetByVersion[version.id]
                if fact.browserDelivery != nil || (verifiedOriginal && PhotoGalleryDerivativeStore.needsBrowserDelivery(photo.enhancedURL)) {
                    // AI preparation may use the verified browser Original, but
                    // it must bind that copy's actual file, asset and bytes.
                    guard verifiedOriginal else { throw PhotoCloudSelectionFailure.changed }
                    let binding = PhotoGalleryDerivativeStore.Source(identity: projection.identity, versionID: version.id,
                        familyID: version.familyID, imageFile: version.imageFile,
                        historySHA256: try PhotoGalleryDerivativeStore.historySHA256(version, directory: photo.enhancedURL.deletingLastPathComponent()),
                        sha256: measured.0, bytes: measured.1)
                    var loaded = try await PhotoGalleryDerivativeStore.shared.lookup(sourceURL: photo.enhancedURL, source: binding)
                    if loaded == nil {
                        loaded = try await PhotoGalleryDerivativeStore.shared.prepare(sourceURL: photo.enhancedURL, source: binding,
                            physicalOrgID: projection.snapshot.orgID, version: version, originalURL: originalURL)
                    }
                    guard let copy = loaded, fact.browserDelivery == nil || copy.delivery == fact.browserDelivery,
                          copy.delivery.physicalOrgID == projection.snapshot.orgID else {
                        throw PhotoCloudSelectionFailure.changed
                    }
                    let actual = try DirectUploader.browserPhoto(copy.url)
                    guard actual.sha256 == copy.delivery.sha256, actual.bytes == copy.delivery.bytes else { throw PhotoCloudSelectionFailure.changed }
                    inputURL = copy.url; input = (actual.sha256, actual.bytes, actual.contentType)
                    asset = try await CloudPhotoReferences.shared.galleryAssetID(fileURL: copy.url, ownerID: context.actorID,
                        orgID: context.orgID, listingID: context.listingID, physicalOrgID: projection.snapshot.orgID)
                    try requireCurrent()
                }
            }
            if asset == nil {
                statusText = "Saving unchanged video photo \(index + 1) of \(photos.count)…"
                let uploaded = try await DirectUploader.uploadPhoto(fileURL: inputURL, listingID: context.listingID,
                    role: "gallery", contentType: input.2, keyPrefix: "gallery", api: model.api)
                asset = UUID(uuidString: uploaded)
                try requireCurrent()
            }
            guard let asset else { throw PhotoCloudSelectionFailure.unmapped }
            let master = PropertyVideoChosenMaster(photoID: photo.id, localVersionID: version.id, assetID: asset,
                sha256: input.0, bytes: input.1, historicalProvenanceID: version.provenanceID.flatMap(UUID.init(uuidString:)))
            let check: @MainActor () throws -> Void = {
                try requireCurrent()
                guard selected == chosenIDs, photo.savedVersion == version else { throw PhotoCloudSelectionFailure.changed }
                try PhotoVersionHistory.requireReelReview(imageURL: photo.enhancedURL)
                guard try DirectUploader.browserPhoto(inputURL).sha256 == input.0,
                      FileStore.fileSize(inputURL) == input.1 else { throw PhotoCloudSelectionFailure.changed }
            }
            statusText = "Preparing chosen video photo \(index + 1) of \(photos.count)…"
            let prepared = try await transform(master, projection.snapshot.orgID, rawOriginals && verifiedOriginal, check)
            try check()
            let digest = await Task.detached(priority: .utility) { DirectUploader.sha256(of: photo.enhancedURL) }.value
            guard digest == measured.0, try DirectUploader.browserPhoto(inputURL).sha256 == input.0,
                  FileStore.fileSize(inputURL) == input.1 else { throw PhotoCloudSelectionFailure.changed }
            result.append(prepared)
        }
        let current = try await model.refreshCloudPhotoSelection(listingID: context.localListingID)
        try requireCurrent()
        guard current.identity == projection.identity, current.snapshot.galleryAssetIDs == gallery,
              current.snapshot.mainPhotoKey == cover, selected == chosenIDs else { throw PhotoCloudSelectionFailure.changed }
        return result
    }

    // MARK: Generate (sequential clips → on-device stitch)

    private var framingSelectionKey: String {
        VideoFramingReviewPolicy.selectionKey(aspect: portrait ? "9:16" : "16:9", photoIDs: selected) + (photoMotion ? ":" + photoMotionProfile.rawValue + ":" + photoMotionDirection.rawValue : "")
    }

    private func generate() {
        guard phase == .setup, canGenerate, !checkingFraming else { return }
        checkingFraming = true
        let key = framingSelectionKey, actor = auth.userID, revision = auth.syncSessionRevision
        let org = WorkspaceContext.selectedOrgID, consent = AIConsent.shared.revocationRevision
        let inputs = selected.compactMap { id in reelPhotos.first(where: { $0.id == id }).map { ($0.id, $0.enhancedURL) } }
        let aspect = portrait ? 9.0 / 16.0 : 16.0 / 9.0, endPush = photoMotion
        let endScale = photoMotionProfile.endScale, direction = photoMotionDirection.rawValue
        Task { @MainActor in
            defer { checkingFraming = false }
            let assessments = await Task.detached(priority: .utility) {
                inputs.compactMap { input in
                    autoreleasepool { VideoPhotoFramingReader.read(photoID: input.0, url: input.1, aspect: aspect, photoMotion: endPush, photoMotionScale: endScale, photoMotionDirection: direction) }
                }
            }.value
            guard work.isPresented, phase == .setup, canGenerate, framingSelectionKey == key,
                  auth.userID == actor, auth.syncSessionRevision == revision, WorkspaceContext.selectedOrgID == org,
                  AIConsent.shared.revocationRevision == consent else { return }
            guard assessments.count == inputs.count else {
                savedPhotoError = "A selected photo couldn't be read. Review it in Photos before creating this video."
                return
            }
            framingAssessments = assessments
            if (photoMotion && acknowledgedFramingKey != key) || VideoFramingReviewPolicy.needsAcknowledgment(assessments: assessments, selectionKey: key, acknowledgedKey: acknowledgedFramingKey) {
                pendingFramingKey = key
                showFramingReview = true
                return
            }
            connection.run {
                if photoMotion { generateWithSession() }
                else { authorizeVideoPreparation { generateWithSession() } }
            }
        }
    }

    private func generateWithSession() {
        let model = self.model, auth = self.auth
        guard phase == .setup, canGenerate else { return }
        if !photoMotion { do { try requirePreparedProcessor() } catch { savedPhotoError = error.localizedDescription; return } }
        let frozenPhotoMotion = photoMotion
        let frozenPhotoProfile = photoMotionProfile
        let frozenOpening = chosenOpening

        let frozenPhotoDirection = photoMotionDirection
        let frozenPhotoFrames = selected.map(photoMotionFrameCount)
        let frozenPhotoDigests = selected.map { id in reelPhotos.first(where: { $0.id == id }).flatMap { photoMotionDigests[PhotoGeometryInput(id: id, url: $0.enhancedURL)] } }
        if frozenPhotoMotion, voiceMode != .off, let voiceover, voiceover.duration > Double(frozenPhotoFrames.reduce(0,+) + (frozenOpening?.reference.visibleFrames ?? 0)) / 24 {
            savedPhotoError = "Your narration is longer than the selected photo times. Shorten it or increase those times; Photo motion will not hold the last frame."; return
        }
        let frozenProcessorPermission = frozenPhotoMotion ? nil : preparedProcessorPermission
        let frozenProcessorContext = preparedProcessorContext
        let frozenProcessorRevision = preparedProcessorRevision
        musicPreview.stop(); voPlayer?.pause()
        let chosen = selected.compactMap { id in reelPhotos.first { $0.id == id } }
        do {
            for photo in chosen { try PhotoVersionHistory.requireReelReview(imageURL: photo.enhancedURL) }
        } catch {
            phase = .failed
            failure = AIFailure(error, title: "Review the selected photo first")
            return
        }
        let extras = selectedExtras.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard chosen.count + extras.count >= 2 else { return }
        let api = model.api                       // snapshot on the main actor
        let isPortrait = portrait
        let prompt = "" // Closed presets keep free text from replacing property-preservation rules.
        let selectedMove = cameraMove?.rawValue ?? "push_in"
        let motionOverride = cameraMove?.rawValue, arrangeScenes = false
        let listingID = listing.id
        let reelActor = auth.userID, reelRevision = auth.syncSessionRevision
        let reelWorkspace = WorkspaceContext.selectedOrgID
        let reelConsentRevision = AIConsent.shared.revocationRevision
        // Caption text is resolved HERE (main actor, plain Sendable strings) —
        // the CALayers themselves are built inside the nonisolated stitch.
        let captions: ReelCaptions? = VideoBrandingPolicy.titleCard(captionsOn ? Self.reelCaptions(for: listing) : nil, aspect: isPortrait ? "9:16" : "16:9")
        // Voiceover + caption-style snapshot on the main actor (both Sendable).
        // `.off` mode → no voiceover; a finished take is used only when the mode
        // isn't .off. captionStyle governs the burned-in spoken-word captions.
        let voiceover: Voiceover? = (voiceMode == .off) ? nil : self.voiceover
        let captionStyle: CaptionStyle = voiceMode != .off && wordCaptionsOn ? .standard : .off
        // The big burned-in shot captions and the transition, snapshot as plain
        // Sendable values like everything else this Task reads.
        let shotStyle: ReelComposer.ShotCaptionStyle = bigCaptionsOn ? bigCaptionStyle : .off
        let transition = reelTransition
        let frozenMusic = musicSelection
        let keepOriginalPhoto = allowOriginalPhotoFallback
        let spaceRaw = space.rawValue
        work.configuration = ReelWorkJob.Configuration(extras: extras, captions: captions, voice: voiceover,
            captionStyle: captionStyle, shotStyle: shotStyle, transition: transition,
            aspect: isPortrait ? "9:16" : "16:9", sourceMode: frozenPhotoMotion ? PhotoMotionContract.mode : nil)
        phase = .generating
        completedClips = 0
        originalPhotoMotionShots = 0
        totalClips = chosen.count
        clipIssues = []
        failure = nil
        statusText = frozenPhotoMotion ? "Preparing Photo motion…" : (chosen.isEmpty ? "Getting ready…" : "Planning your shots…")
        Haptics.selection()
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reel-\(UUID().uuidString)", isDirectory: true)
        let isSample = listing.isSample
        work.start(identityIsCurrent: { [model, id = listing.id] in model.listings.contains { $0.id == id && $0.cloudUnavailable != true } }, resume: { resumePausedWork() }) {
            // Hoisted OUT of the `do` so the `catch` can still see them. These are
            // the clips the account has ALREADY BEEN CHARGED FOR; the catch below
            // used to delete the directory holding them before it had even looked
            // at why it was running (the 4,000 sq ft field test).
            var billedClips: [URL] = []
            do {
                try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
                // Anchor every generated clip to the listing so the motion is
                // disclosed on the tour and lands in the broker's audit log.
                var reelListingServerID: UUID? = nil
                if !isSample {
                    reelListingServerID = await model.serverListingIDForCompliance(listingID)
                }
                var plan: [AIShot] = []
                var ordered = chosen
                try Task.checkCancellation()

                var clipURLs: [URL] = extras          // ready-made clips lead the reel
                // The plan entries that actually produced a clip, in clip order.
                // Kept in step with `clipURLs` so a failed clip cannot slide every
                // later caption onto the wrong picture.
                var usedShots: [AIShot?] = []
                let targetServerID = reelListingServerID
                let recoveryContext = reelActor.map { PendingReelRequest.Context(listingID: listingID,
                    serverListingID: targetServerID, owner: $0, workspace: reelWorkspace) }
                let requireCurrent: @MainActor @Sendable () throws -> Void = {
                    try Task.checkCancellation()
                    if !frozenPhotoMotion {
                        guard AIConsent.shared.isGranted, AIConsent.shared.revocationRevision == reelConsentRevision,
                              PropertyVideoProcessorConsent.shared.revision == frozenProcessorRevision else { throw CancellationError() }
                    }
                    if let permission = frozenProcessorPermission, let context = frozenProcessorContext {
                        guard PropertyVideoProcessorConsent.shared.permits(permission, context: context) else { throw PropertyVideoProcessorFailure.permissionRequired }
                    }
                    guard chosenOpening == frozenOpening else { throw PropertyVideoJobStore.Failure.identityChanged }
                    guard auth.userID == reelActor, auth.syncSessionRevision == reelRevision,
                          WorkspaceContext.selectedOrgID == reelWorkspace,
                          let current = model.listings.first(where: { $0.id == listingID }),
                          current.cloudUnavailable != true, current.serverID == targetServerID else {
                        throw CancellationError()
                    }
                }
                // Normal background photo videos use exact chosen masters and
                // server-proven JPEG aliases. Never silently fall back to a new
                // client-reencoded upload carrying historical NULL provenance.
                if !isSample, extras.isEmpty {
                    guard let targetServerID, let actor = reelActor.flatMap(UUID.init(uuidString:)), let org = reelWorkspace,
                          let jobsAPI = api as? any PropertyVideoJobsAPI, let recoveryContext else { throw PropertyVideoJobStore.Failure.identityChanged }
                    guard !PendingReelBatch.exists(recoveryContext), !PendingReelRequest.exists(recoveryContext) else {
                        throw AIImagePrep.error("Continue or discard the saved video before preparing another recipe.")
                    }
                    let context = PropertyVideoJobContext(localListingID: listingID, listingID: targetServerID, actorID: actor, orgID: org)
                    let sources: [PropertyVideoJobSource]
                    let shotLabels: [String?]
                    if frozenPhotoMotion {
                        var physicalOrgID: UUID?
                        let choices = try await withChosenVideoMasters(chosen, context: context, maximumMasterBytes: 52_428_800, rawOriginals: true, requireCurrent: requireCurrent) { master, orgID, rawOriginal, check in
                            try check()
                            guard physicalOrgID == nil || physicalOrgID == orgID else { throw PropertyVideoJobStore.Failure.identityChanged }
                            physicalOrgID = orgID
                            return (master: master, rawOriginal: rawOriginal)
                        }
                        let masters = choices.map(\.master)
                        guard let physicalOrgID, masters.count == frozenPhotoFrames.count,
                              zip(chosen, frozenPhotoDigests).allSatisfy({ DirectUploader.sha256(of: $0.enhancedURL) == $1 }) else { throw PropertyVideoJobStore.Failure.invalidReceipt }
                        let localVersions = chosen.map(\.savedVersion)
                        let catalogue = choices.allSatisfy(\.rawOriginal) ? [] :
                            try await jobsAPI.photoMotionCatalogue(context: context, physicalOrgID: physicalOrgID, requireCurrent: requireCurrent)
                        try requireCurrent()
                        guard selected == chosen.map(\.id), chosen.map(\.savedVersion) == localVersions else { throw PropertyVideoJobStore.Failure.identityChanged }
                        sources = try choices.enumerated().map { index, choice in
                            if choice.rawOriginal {
                                return try PhotoMotionContract.source(choice.master, visibleFrames: frozenPhotoFrames[index], motion: frozenPhotoDirection.rawValue)
                            }
                            return try PropertyVideoPhotoCatalogue.resolve([choice.master], frames: [frozenPhotoFrames[index]], sources: catalogue, motion: frozenPhotoDirection.rawValue)[0]
                        }
                        shotLabels = sources.map { _ in nil }
                        scenePlanningNotice = nil
                    } else {
                        let prepared = try await prepareChosenVideoMasters(chosen, context: context, jobsAPI: jobsAPI, requireCurrent: requireCurrent)
                        try requireCurrent()
                        let inputs = zip(chosen, prepared).map { photo, source in PropertyVideoPlanner.Input(photoID: photo.id, assetID: source.source!.assetID, jpegDigest: source.source!.sha256) }
                        let planned = try await PropertyVideoPlanner.plan(inputs: inputs, context: .init(ownerID: actor, orgID: org, listingID: targetServerID),
                            api: api as? PropertyVideoPlanningAPI, automaticOrder: false, documents: FileStore.documents, requireCurrent: requireCurrent)
                        let orderedPlan = try PropertyVideoPlanner.preservingInputOrder(planned.photos, inputs: inputs)
                        guard prepared.count == chosen.count, orderedPlan.count == chosen.count else { throw PropertyVideoJobStore.Failure.invalidReceipt }
                        sources = try prepared.enumerated().map { index, source in try source.jobSource(motion: motionOverride ?? orderedPlan[index].motion) }
                        shotLabels = orderedPlan.map { shotStyle.isOn ? $0.caption : nil }
                        scenePlanningNotice = planned.notice
                    }
                    let title = captions.map { PropertyVideoPresentation.Title(title: $0.title, subtitle: $0.subtitle, watermark: $0.watermark) }
                    let presentation = PropertyVideoPresentation(transition: transition.rawValue, shotCaptionStyle: shotStyle.rawValue,
                        spokenCaptions: captionStyle.enabled && voiceover != nil, titleCard: title,
                        shotLabels: shotLabels)
                    guard frozenMusic == nil || frozenMusic?.checked(catalog: VideoMusicCatalog.tracks) != nil else { throw PropertyVideoJobStore.Failure.invalidReceipt }
                    let narrationResult = voiceover?.sharedReference?.resultID(ownerID: actor, listingID: targetServerID)
                    var request = PropertyVideoJobRequest(operationID: UUID(), listingID: targetServerID, expectedOrgID: org,
                        purpose: isPortrait ? "social" : "listing", aspect: isPortrait ? "9:16" : "16:9", sources: sources,
                        narrationResultID: narrationResult, music: frozenMusic, allowOriginalPhotoFallback: frozenPhotoMotion ? false : keepOriginalPhoto, presentation: presentation,
                        motionOverride: frozenPhotoMotion ? nil : motionOverride, sourceMode: frozenPhotoMotion ? PhotoMotionContract.mode : nil,
                        compositionProfile: frozenPhotoMotion ? (frozenOpening == nil ? frozenPhotoProfile.rawValue : PhotoMotionContract.Profile.opening.rawValue) : nil,
                        opening: frozenOpening?.reference)
                    if let voiceover, narrationResult == nil {
                        request.narrationAssetID = try await PropertyVideoNarrationUpload.upload(voiceover, operationID: request.operationID, context: context, requireCurrent: requireCurrent)
                        request.narrationWords = captionStyle.enabled ? voiceover.words.map { .init(text: $0.text, start: $0.start, end: $0.end) } : nil
                    }
                    try requireCurrent()
                    if let frozenOpening {
                        let live = try await AerialOpeningService.catalogue(context: context, physicalOrgID: frozenOpening.scope.orgID, aspect: request.aspect)
                        try requireCurrent()
                        guard live.accepted.contains(where: { $0.opening == frozenOpening }) else { throw PropertyVideoJobStore.Failure.invalidReceipt }
                    }
                    let saved = PropertyVideoSavedJob(context: context, request: request, createdAt: Date(), processorPermission: frozenProcessorPermission)
                    try PropertyVideoJobStore.start(saved, documents: FileStore.documents)
                    work.serverJob = saved; statusText = "Sending your saved video recipe…"
                    try await PropertyVideoJobRunner.shared.enqueue(saved, work: work, model: model, api: jobsAPI)
                    try requireCurrent()
                    try? FileManager.default.removeItem(at: tmpDir)
                    return
                }
                guard !frozenPhotoMotion else { throw PropertyVideoJobStore.Failure.invalidReceipt }
                var batch: PendingReelBatch? = nil
                if !ordered.isEmpty, let recoveryContext {
                    try requireCurrent()
                    guard !PendingReelBatch.exists(recoveryContext) else { throw AIImagePrep.error("Continue or discard the saved reel before starting another batch.") }
                    var prepared: [PendingReelBatch.Photo] = []
                    let stagedInputs = try await VideoPreparedSourcePolicy.stage(chosen,
                        aspect: isPortrait ? "9:16" : "16:9", directory: tmpDir,
                        maximumJPEGBytes: VideoSelectionCapacity.maximumPreparedJPEGBytes,
                        maximumBase64Bytes: VideoSelectionCapacity.maximumPreparedBase64Bytes,
                        progress: { number, total in statusText = "Preparing photo \(number) of \(total)…" },
                        requireCurrent: requireCurrent,
                        prepare: { try Self.preparedReelJPEG(photo: $0, aspect: isPortrait ? "9:16" : "16:9") })
                    for (index, photo) in chosen.enumerated() {
                        try requireCurrent()
                        let input = stagedInputs[index]
                        let jpeg = try Data(contentsOf: input)
                        let encoded = jpeg.base64EncodedString()
                        // Private input upload leaves the public gallery untouched.
                        // Its exact JPEG binds generation/QC source authority.
                        var sourceAssetID: String? = nil
                        if let targetServerID {
                            let photoNumber = prepared.count + 1
                            await MainActor.run { statusText = "Uploading photo \(photoNumber) of \(chosen.count)…" }
                            sourceAssetID = try await DirectUploader.uploadPhoto(fileURL: input, listingID: targetServerID,
                                role: "capture", contentType: "image/jpeg", keyPrefix: "video-source", api: api)
                            try requireCurrent()
                        }
                        try? FileManager.default.removeItem(at: input)
                        prepared.append(PendingReelBatch.Photo(id: photo.id, jpegBase64: encoded,
                            shot: nil,
                            sourceAssetID: sourceAssetID, photoProvenanceID: photo.savedVersion?.provenanceID))
                        await Task.yield()
                    }
                    // All exact private JPEGs exist before classification. Freeze
                    // the complete global order and per-photo motion before any clip POST.
                    var plannedPhotos: [PropertyVideoPlanner.Planned] = []
                    var planningFallback = true
                    var planningNotice = "Automatic scene planning wasn't available. Keeping your selected order with restrained motion."
                    if let sid = targetServerID, let owner = UUID(uuidString: recoveryContext.owner), let org = recoveryContext.workspace {
                        let inputs = try prepared.map { photo -> PropertyVideoPlanner.Input in
                            guard let asset = photo.sourceAssetID.flatMap(UUID.init(uuidString:)), let jpeg = Data(base64Encoded: photo.jpegBase64) else {
                                throw PropertyVideoPlanner.Failure.invalidInput
                            }
                            return PropertyVideoPlanner.Input(photoID: photo.id, assetID: asset, jpegDigest: PropertyVideoPlanner.digest(jpeg))
                        }
                        await MainActor.run { statusText = "Choosing camera motion for your photos…" }
                        let result = try await PropertyVideoPlanner.plan(inputs: inputs,
                            context: .init(ownerID: owner, orgID: org, listingID: sid), api: api as? PropertyVideoPlanningAPI,
                            automaticOrder: arrangeScenes, documents: FileStore.documents, requireCurrent: requireCurrent)
                        plannedPhotos = try PropertyVideoPlanner.preservingInputOrder(result.photos, inputs: inputs)
                        planningFallback = result.usedFallback; planningNotice = result.notice
                    }
                    try requireCurrent()
                    let byID = Dictionary(uniqueKeysWithValues: prepared.map { ($0.id, $0) })
                    let frozenIDs = plannedPhotos.isEmpty ? prepared.map(\.id) : plannedPhotos.map { $0.input.photoID }
                    let plannedByID = Dictionary(uniqueKeysWithValues: plannedPhotos.map { ($0.input.photoID, $0) })
                    prepared = frozenIDs.enumerated().map { index, id in
                        let original = byID[id]!, scene = plannedByID[id]
                        let shot = AIShot(photoID: id, order: index + 1, motion: motionOverride ?? scene?.motion ?? "push_in",
                            room: scene?.confident == true ? scene?.scene.rawValue : nil,
                            onScreenText: scene?.caption, seconds: 5, voiceLine: nil)
                        return PendingReelBatch.Photo(id: id, jpegBase64: original.jpegBase64, shot: .init(shot),
                            sourceAssetID: original.sourceAssetID, photoProvenanceID: original.photoProvenanceID)
                    }
                    plan = prepared.compactMap { $0.shot?.value }
                    ordered = Self.reordered(chosen, by: plan)
                    await MainActor.run { scenePlanningNotice = planningNotice }
                    batch = PendingReelBatch(context: recoveryContext, id: UUID(), photos: prepared,
                        motion: selectedMove, aspect: isPortrait ? "9:16" : "16:9", spaceType: spaceRaw, completedPaths: [], framing: "preserve_photo", scenePlanVersion: 1,
                        scenePlanningNotice: planningNotice, automaticOrder: arrangeScenes, usedPlanningFallback: planningFallback)
                    try requireCurrent()
                    try batch?.save()
                }
                if !isSample, extras.isEmpty, let prepared = batch, let targetServerID,
                   let actor = reelActor.flatMap(UUID.init(uuidString:)), let org = reelWorkspace,
                   let jobsAPI = api as? PropertyVideoJobsAPI {
                    try requireCurrent()
                    guard frozenMusic == nil || frozenMusic?.checked(catalog: VideoMusicCatalog.tracks) != nil else {
                        throw PropertyVideoJobStore.Failure.invalidReceipt
                    }
                    let context = PropertyVideoJobContext(localListingID: listingID, listingID: targetServerID, actorID: actor, orgID: org)
                    let sources = try prepared.photos.map { photo -> PropertyVideoJobSource in
                        guard let asset = photo.sourceAssetID.flatMap(UUID.init(uuidString:)) else { throw PropertyVideoJobStore.Failure.invalidReceipt }
                        return PropertyVideoJobSource(photoID: photo.id, photoAssetID: asset, photoVersionID: photo.id,
                            photoProvenanceID: photo.photoProvenanceID.flatMap(UUID.init(uuidString:)), motion: photo.shot?.motion ?? selectedMove)
                    }
                    let title = captions.map { PropertyVideoPresentation.Title(title: $0.title, subtitle: $0.subtitle, watermark: $0.watermark) }
                    let presentation = PropertyVideoPresentation(transition: transition.rawValue, shotCaptionStyle: shotStyle.rawValue,
                        spokenCaptions: captionStyle.enabled && voiceover != nil, titleCard: title,
                        shotLabels: prepared.photos.map { shotStyle.isOn ? $0.shot?.onScreenText : nil })
                    let narrationResult = voiceover?.sharedReference?.resultID(ownerID: actor, listingID: targetServerID)
                    var request = PropertyVideoJobRequest(operationID: UUID(), listingID: targetServerID, expectedOrgID: org,
                        purpose: isPortrait ? "social" : "listing", aspect: isPortrait ? "9:16" : "16:9", sources: sources,
                        narrationResultID: narrationResult, music: frozenMusic, allowOriginalPhotoFallback: keepOriginalPhoto, presentation: presentation,
                        motionOverride: motionOverride)
                    if let voiceover, narrationResult == nil {
                        statusText = "Uploading your optional narration…"
                        request.narrationAssetID = try await PropertyVideoNarrationUpload.upload(voiceover, operationID: request.operationID,
                            context: context, requireCurrent: requireCurrent)
                        request.narrationWords = captionStyle.enabled ? voiceover.words.map { .init(text: $0.text, start: $0.start, end: $0.end) } : nil
                        try requireCurrent()
                    }
                    let saved = PropertyVideoSavedJob(context: context, request: request, createdAt: Date(), processorPermission: frozenProcessorPermission)
                    try PropertyVideoJobStore.start(saved, documents: FileStore.documents) // Persist before enqueue.
                    work.serverJob = saved
                    statusText = "Sending your saved video recipe…"
                    try await PropertyVideoJobRunner.shared.enqueue(saved, work: work, model: model, api: jobsAPI)
                    try requireCurrent()
                    prepared.clear(); pendingBatch = nil
                    try? FileManager.default.removeItem(at: tmpDir)
                    return // No native provider polling or stitching after server acceptance.
                }
                guard frozenMusic == nil else {
                    throw AIImagePrep.error("Music is available for background photo videos. Remove the opening clip or choose Off; no new clips were requested.")
                }
                for (i, photo) in ordered.enumerated() {
                    try Task.checkCancellation()
                    try requireCurrent()
                    guard AIConsent.shared.isGranted, AIConsent.shared.revocationRevision == reelConsentRevision else {
                        throw CancellationError()
                    }
                    await MainActor.run { statusText = "Photo \(i + 1) of \(ordered.count) — making video…" }
                    let shot = Self.shot(for: photo, in: plan)
                    do {
                        let clip = try await Self.makeClip(photo: photo, prompt: prompt,
                                                           shot: shot, shotCount: ordered.count,
                                                           motion: shot?.motion ?? selectedMove, aspect: isPortrait ? "9:16" : "16:9", spaceType: spaceRaw,
                                                           api: api, listingServerID: reelListingServerID,
                                                           into: tmpDir, index: i, recoveryContext: recoveryContext,
                                                           requireCurrent: requireCurrent,
                                                           preparedJPEG: batch.flatMap { Data(base64Encoded: $0.photos[i].jpegBase64) },
                                                           framing: batch?.framing,
                                                           sourceAssetID: batch?.photos[i].sourceAssetID,
                                                           photoProvenanceID: batch?.photos[i].photoProvenanceID)
                        if batch != nil {
                            batch = try PendingReelBatch.load(recoveryContext!)
                        }
                        clipURLs.append(clip)
                        usedShots.append(shot)
                        billedClips.append(clip)   // retained before its accepted receipt is cleared
                        if OriginalPhotoMotion.isClip(clip) { originalPhotoMotionShots += 1 }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        // Continuing hid the reason and could send every other
                        // photo to an unavailable service. Stop, retain the exact
                        // photo position, and park completed clips in the catch.
                        await MainActor.run {
                            clipIssues.append(ReelClipIssue(photoNumber: i + 1, error: error))
                            completedClips = i + 1
                        }
                        throw error
                    }
                    await MainActor.run { completedClips = i + 1 }
                }
                guard clipURLs.count >= 1, clipURLs.count > extras.count || chosen.isEmpty else {
                    throw AIImagePrep.error("None of the clips could be generated. Please try again.")
                }
                try Task.checkCancellation()
                await MainActor.run { phase = .stitching }

                let renderSize = isPortrait ? CGSize(width: 1080, height: 1920)
                                            : CGSize(width: 1920, height: 1080)
                let reelsDir = FileStore.documents.appendingPathComponent("reels", isDirectory: true)
                try FileManager.default.createDirectory(at: reelsDir, withIntermediateDirectories: true)
                let stamp = "\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString)"
                let outURL = reelsDir.appendingPathComponent("\(listingID.uuidString)-\(stamp).mp4")
                let photoClips = Array(clipURLs.dropFirst(extras.count))
                try await ReelComposer.compose(
                    shots: Self.shots(extras: extras, photoClips: photoClips,
                                      plan: usedShots, captionsOn: shotStyle.isOn),
                    renderSize: renderSize,
                    options: ReelComposer.Options(titleCard: captions, voiceover: voiceover,
                                                  captionStyle: captionStyle,
                                                  shotCaptionStyle: shotStyle,
                                                  transition: transition),
                    output: outURL)
                try requireCurrent()
                try OriginalPhotoMotion.saveSummary(count: clipURLs.filter(OriginalPhotoMotion.isClip).count, for: outURL)
                let finishedRecord = try await ListingVideoPreparation.retain(output: outURL, listingID: listingID,
                    ownerID: reelActor, workspaceID: reelWorkspace, serverListingID: reelListingServerID,
                    purpose: isPortrait ? .socialMedia : .listing, sources: batch?.completedSources ?? [],
                    includesOpeningClip: !extras.isEmpty, brandingPolicy: isPortrait ? nil : "unbranded")
                try requireCurrent()
                if finishedRecord.canSelectForWebsite, model.listings.first(where: { $0.id == listingID })?.websiteVideoRelPath == nil {
                    try await model.selectWebsiteVideo(finishedRecord, for: listingID, onlyIfUnselected: true)
                    try requireCurrent()
                }
                try? FileManager.default.removeItem(at: tmpDir)

                try requireCurrent()
                let wasPlanned = usedShots.contains(where: { $0 != nil }) ? "true" : "false"
                await MainActor.run {
                    reelURL = outURL
                    originalPhotoMotionShots = clipURLs.filter(OriginalPhotoMotion.isClip).count
                    player = AVPlayer(url: outURL)
                    lastReel = outURL
                    phase = .done
                    Haptics.success()
                    Analytics.track("reel_made", ["ok": "true", "clips": String(clipURLs.count),
                                                  "captions": shotStyle.rawValue,
                                                  "transition": transition.rawValue,
                                                  "planned": wasPlanned])
                }
                batch?.clear()
                PendingReelClips.retire(billedClips, for: listingID)
                // The new reel is safely on disk AND on screen — now, and only
                // now, trim the older ones so Documents/reels can't grow without
                // bound (F-A-23). Off the main actor and never cancellable: a
                // half-finished prune would still be consistent, but the user's
                // result must never wait on it.
                await Task.detached(priority: .utility) {
                    ReelStudioView.pruneReels(for: listingID, keeping: reelsKeptPerListing)
                }.value
            } catch {
                // KEEP THE PAID WORK — this is the whole fix. Whichever way this
                // run ended, the clips already generated cost real money and are
                // the one thing a retry cannot get back for free, so they are
                // moved somewhere durable BEFORE the temp directory goes.
                //
                // Both exits park, not just cancellation: a quota wall or an
                // expired session on clip 4 of 6 does not make clips 1–3
                // worthless, and the old code binned those too.
                Self.parkClips(billedClips, for: listingID, tmpDir: tmpDir)
                if error is CancellationError || Task.isCancelled {
                    // Cancelled means the sheet is already gone (Close, a swipe,
                    // or the Cancel button) — there is no UI left to talk to. The
                    // next open reads the parked clips back in `onAppear`, the way
                    // AerialIntroSheet resumes a PendingAerialJob.
                    return
                }
                await MainActor.run {
                    Analytics.trackAIFailure("reel", step: "clips", error: error)
                    parkedClips = PendingReelClips.load(for: listingID)
                    reloadPendingRequest()
                    phase = .failed
                    failure = ReelClipIssue.failure(for: error, title: "Couldn't make the reel")
                }
            }
        }
    }

    /// Move clips that were already generated — and already CHARGED — out of the
    /// run's temp directory into `Documents/reels/<id>-parked/`, record them, and
    /// then (and only then) delete the temp directory.
    ///
    /// ADDS to whatever is already parked rather than replacing it: a second
    /// abandoned run does not make the first run's clips worthless, and both were
    /// billed. Names carry the run's timestamp so two runs cannot collide.
    ///
    /// `nonisolated` and fully synchronous on purpose. It runs inside the `catch`
    /// of a CANCELLED task, after the view has already been dismissed, so it must
    /// not need the main actor and must not `await` anything — an `await` in a
    /// cancelled task is exactly how this work would get lost a second time.
    nonisolated private static func parkClips(_ clips: [URL], for listingID: UUID, tmpDir: URL) {
        let fm = FileManager.default
        var canRemoveTemporary = clips.isEmpty
        defer { if canRemoveTemporary { try? fm.removeItem(at: tmpDir) } }
        guard !clips.isEmpty else { return }
        let dir = PendingReelClips.directory(for: listingID)
        let previous: PendingReelClips?
        do {
            previous = try PendingReelClips.readRecord(for: listingID)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return   // Keep the only copies when storage/history is unavailable.
        }
        // Start from what is already parked, dropping any entry whose file has
        // since gone so the record can't accumulate dead paths.
        var relPaths = (previous?.clipURLs ?? [])
            .map { FileStore.relativePath(for: $0) }
        var allRetained = true
        for clip in clips {
            guard fm.fileExists(atPath: clip.path) else { continue }
            if relPaths.contains(FileStore.relativePath(for: clip)) { continue }
            let prefix = OriginalPhotoMotion.isClip(clip) ? "clip-photo-motion-" : "clip-"
            let dest = dir.appendingPathComponent("\(prefix)\(UUID().uuidString).mp4")
            do {
                try fm.moveItem(at: clip, to: dest)
            } catch {
                // tmp and Documents are the same volume so a move should not
                // fail — but a copy is the difference between keeping the agent's
                // money and losing it, so try that before giving up on this clip.
                do { try fm.copyItem(at: clip, to: dest) } catch { allRetained = false; continue }
            }
            relPaths.append(FileStore.relativePath(for: dest))
        }
        guard !relPaths.isEmpty else { return }
        do {
            try PendingReelClips(listingID: listingID, savedAt: Date(), relPaths: relPaths).saveDurably()
            canRemoveTemporary = allRetained
        } catch { return }
    }

    /// Stitch the parked clips into a reel. NO AI call, no network, no spend —
    /// the clips were bought on an earlier run; this is the free half of the job
    /// the old cancel path threw away.
    ///
    /// Finish paid clips with the saved job's settings and durable batch shape.
    /// Only older clips without saved settings use the current setup.
    nonisolated private static func parkedReelSettings(configuration: ReelWorkJob.Configuration?,
        batchAspect: String?, fallback: ReelWorkJob.Configuration) -> (configuration: ReelWorkJob.Configuration, renderSize: CGSize) {
        let settings = configuration ?? fallback
        let aspect = batchAspect ?? settings.aspect ?? fallback.aspect
        return (settings, aspect == "16:9" ? CGSize(width: 1920, height: 1080) : CGSize(width: 1080, height: 1920))
    }

    nonisolated private static func requireSavedReelReview(_ batch: PendingReelBatch?) throws {
        guard let batch else { return }
        let directory = EnhancedPhoto.directory(for: batch.context.listingID)
        for photo in batch.photos { try PhotoVersionHistory.requireReelReview(versionID: photo.id, directory: directory) }
    }

    private func finishParkedReel() {
        let model = self.model, auth = self.auth
        guard !isWorking else { return }
        do { try Self.requireSavedReelReview(pendingBatch) }
        catch { failure = AIFailure(error, title: "Review the saved photo first"); return }
        let settings = Self.parkedReelSettings(configuration: work.configuration,
            batchAspect: pendingBatch?.aspect, fallback: snapshotReelConfiguration())
        let configuration = settings.configuration
        let clips = (configuration.extras.filter { FileManager.default.fileExists(atPath: $0.path) })
            + (parkedClips?.clipURLs ?? [])
        guard !clips.isEmpty else {
            parkedClips = nil
            return
        }
        if recorder.isRecording { recorder.cancel() }   // never leave the mic hot
        let listingID = listing.id
        let parkedActor = auth.userID, parkedRevision = auth.syncSessionRevision
        let parkedWorkspace = WorkspaceContext.selectedOrgID
        let parkedConsent = AIConsent.shared.revocationRevision
        let parkedServerID = listing.serverID
        let requireCurrent: @MainActor @Sendable () throws -> Void = {
            try Task.checkCancellation()
            guard AIConsent.shared.isGranted, AIConsent.shared.revocationRevision == parkedConsent,
                  auth.userID == parkedActor, auth.syncSessionRevision == parkedRevision,
                  WorkspaceContext.selectedOrgID == parkedWorkspace,
                  let current = model.listings.first(where: { $0.id == listingID }),
                  current.cloudUnavailable != true, current.serverID == parkedServerID else { throw CancellationError() }
        }
        let captions = VideoBrandingPolicy.titleCard(configuration.captions, aspect: settings.renderSize.width < settings.renderSize.height ? "9:16" : "16:9")
        let voiceover = configuration.voice
        let captionStyle = configuration.captionStyle
        failure = nil
        clipIssues = []
        phase = .stitching
        Haptics.selection()
        work.configuration = configuration
        work.start(identityIsCurrent: { [model, id = listing.id] in model.listings.contains { $0.id == id && $0.cloudUnavailable != true } }, resume: { resumePausedWork() }) {
            do {
                try requireCurrent()
                let renderSize = settings.renderSize
                let reelsDir = FileStore.documents.appendingPathComponent("reels", isDirectory: true)
                try FileManager.default.createDirectory(at: reelsDir, withIntermediateDirectories: true)
                let stamp = "\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString)"
                let outURL = reelsDir.appendingPathComponent("\(listingID.uuidString)-\(stamp).mp4")
                // Parked clips have no shot plan — the run that bought them ended
                // before one could be attached to a file on disk — so they are
                // composed the way every reel was composed before the planner
                // existed: whole clips, hard cuts, no shot captions. The point of
                // this path is to give back work already paid for, not to make it
                // better than it was.
                try await ReelComposer.compose(
                    shots: clips.map { ReelComposer.Shot(url: $0) },
                    renderSize: renderSize,
                    options: ReelComposer.Options(titleCard: captions, voiceover: voiceover,
                        captionStyle: captionStyle, shotCaptionStyle: configuration.shotStyle,
                        transition: configuration.transition),
                    output: outURL)
                try OriginalPhotoMotion.saveSummary(count: clips.filter(OriginalPhotoMotion.isClip).count, for: outURL)
                let recipe = pendingBatch
                let sources = recipe?.completedPaths == parkedClips?.relPaths ? recipe?.completedSources ?? [] : []
                let finishedRecord = try await ListingVideoPreparation.retain(output: outURL, listingID: listingID,
                    ownerID: parkedActor, workspaceID: parkedWorkspace, serverListingID: parkedServerID,
                    purpose: renderSize.width > renderSize.height ? .listing : .socialMedia, sources: sources,
                    includesOpeningClip: !configuration.extras.isEmpty, brandingPolicy: settings.renderSize.width > settings.renderSize.height ? "unbranded" : nil)
                try requireCurrent()
                if finishedRecord.canSelectForWebsite, model.listings.first(where: { $0.id == listingID })?.websiteVideoRelPath == nil {
                    try await model.selectWebsiteVideo(finishedRecord, for: listingID, onlyIfUnselected: true)
                    try requireCurrent()
                }
                await MainActor.run {
                    // The clips now live inside a finished reel on disk, so the
                    // parked copy has done its job and can go. This is the ONLY
                    // automatic delete of paid clips in the whole flow.
                    pendingBatch?.clear()
                    pendingBatch = nil
                    PendingReelClips.retire(clips, for: listingID)
                    parkedClips = PendingReelClips.load(for: listingID)
                    reelURL = outURL
                    originalPhotoMotionShots = clips.filter(OriginalPhotoMotion.isClip).count
                    player = AVPlayer(url: outURL)
                    lastReel = outURL
                    phase = .done
                    Haptics.success()
                    Analytics.track("reel_made", ["ok": "true", "clips": String(clips.count),
                                                  "resumed": "true"])
                }
                await Task.detached(priority: .utility) {
                    ReelStudioView.pruneReels(for: listingID, keeping: reelsKeptPerListing)
                }.value
            } catch {
                // Cancelled or failed, the clips STAY parked — nothing here ever
                // deletes them, which is the point of the whole card.
                if error is CancellationError || Task.isCancelled { return }
                await MainActor.run {
                    phase = .failed
                    failure = AIFailure(error, title: "Couldn't finish that reel")
                }
            }
        }
    }

    /// Delete the parked clips at the agent's explicit request (confirmed first).
    private func discardParkedClips() {
        pendingBatch?.clear()
        PendingReelClips.clear(for: listing.id)
        parkedClips = nil
        reloadPendingRequest()
        Haptics.selection()
    }

    /// One photo → 5 s AI motion clip: downscale ≤2048 → high-quality JPEG → submit
    /// `ai-video/reel-clip` → poll every 5 s (cap 5 min) → download the mp4 into
    /// `dir`. fal result URLs expire, so the download happens immediately.
    ///
    /// `shot` is this photo's entry in the plan, when there is one. It carries the
    /// CAMERA MOVE, which is the single biggest reason reels looked amateur: with
    /// no plan every clip was submitted with nothing, every clip came back with
    /// the server's one default push-in, and six identical push-ins in a row is
    /// what "AI slop" looks like. Nil stays nil all the way to the wire — see
    /// `APIClient.aiVideoReelClip`.
    ///
    /// STILL FIVE SECONDS, always. The plan's `seconds` paces the EDIT, not the
    /// generation: a shorter clip would change what a reel costs and what the
    /// setup screen promised ("Every photo you pick becomes 5 seconds of video"),
    /// and trimming 5 s down on-device is free.
    nonisolated private static func makeClip(photo: EnhancedPhoto, prompt: String,
                                             shot: AIShot?, shotCount: Int,
                                             motion: String, aspect: String, spaceType: String,
                                             api: APIClient, listingServerID: UUID?,
                                             into dir: URL, index: Int,
                                             recoveryContext: PendingReelRequest.Context? = nil,
                                             requireCurrent: @MainActor @Sendable () throws -> Void = { try Task.checkCancellation() },
                                             preparedJPEG: Data? = nil, framing: String? = nil,
                                             sourceAssetID: String? = nil, photoProvenanceID: String? = nil) async throws -> URL {
        try await requireCurrent()
        guard let recoveryContext else { throw AIImagePrep.error("Reconnect your account before generating this clip.") }
        if PendingReelRequest.exists(recoveryContext) {
            throw AIImagePrep.error("Recover or forget the saved video request before generating again.")
        }
        _ = try PendingReelClips.readRecord(for: recoveryContext.listingID)
        let jpeg = try preparedJPEG ?? Self.preparedReelJPEG(photo: photo, aspect: aspect)
        guard !jpeg.isEmpty else { throw AIImagePrep.error("Couldn't prepare that photo.") }
        if let batch = try PendingReelBatch.load(recoveryContext) {
            guard batch.completedPaths.count == index, index < batch.photos.count,
                  batch.photos[index].id == photo.id, batch.photos[index].jpegBase64 == jpeg.base64EncodedString(),
                  batch.aspect == aspect, batch.spaceType == spaceType, batch.framing == framing,
                  batch.scenePlanVersion != 1 || (batch.photos[index].shot?.motion ?? batch.motion) == motion else {
                throw AIImagePrep.error("This photo does not match the saved reel. Continue the saved batch instead.")
            }
        }
        // No motion text → send NOTHING and let `/ai-video/reel-clip` use its own
        // space-aware anti-hallucination prompt (F-A-24). Sending a canned client
        // sentence took the caller-supplied branch instead, which both skipped
        // the server's stronger default and wrote our own words into the
        // listing's provenance log as if the agent had typed them.
        let typed: String? = prompt.isEmpty ? nil : prompt
        try await requireCurrent()
        for attempt in 0...1 {
            try await requireCurrent()
            let attemptMotion = attempt == 0 ? motion : "push_in"
            let operationID = UUID().uuidString
            var intent = try JSONEncoder().encode([typed ?? "", attemptMotion, aspect, "preset-v1", shot?.room ?? "",
                String(index), String(shotCount), listingServerID?.uuidString ?? "", framing ?? "legacy"])
            intent.append(jpeg)
            let digest = SHA256.hash(data: intent).map { String(format: "%02x", $0) }.joined()
            let submission = PendingReelRequest(context: recoveryContext, photoNumber: index + 1,
                job: AIVideoJob(requestId: operationID, statusUrl: "", responseUrl: "", kind: "reel"),
                operationID: operationID, inputDigest: digest, submissionUnconfirmed: true,
                sourceJPEGBase64: jpeg.base64EncodedString(), sourceSpaceType: spaceType, qualityAttempt: attempt, framing: framing, outputAspect: aspect, sourceAssetID: sourceAssetID, photoProvenanceID: photoProvenanceID)
            try submission.save() // Atomic marker and readback BEFORE any paid POST.
            try await requireCurrent()
            let job: AIVideoJob
            do {
                if let sourceAssetID {
                    job = try await api.aiVideoReelClip(imageBase64: jpeg.base64EncodedString(), mime: "image/jpeg", prompt: nil, seconds: 5,
                        aspect: aspect, framing: framing, presetVersion: 1, motion: attemptMotion, room: shot?.room,
                        shotIndex: index, shotCount: shotCount, listingServerID: listingServerID,
                        label: Self.clipLabel(shot: shot, index: index), idempotencyKey: operationID,
                        sourceAssetID: sourceAssetID, sourceProvenanceID: photoProvenanceID)
                } else {
                job = try await api.aiVideoReelClip(imageBase64: jpeg.base64EncodedString(),
                                                    mime: "image/jpeg", prompt: nil, seconds: 5,
                                                    aspect: aspect, framing: framing, presetVersion: 1,
                                                    motion: attemptMotion, room: shot?.room,
                                                    shotIndex: index, shotCount: shotCount,
                                                    listingServerID: listingServerID,
                                                    label: Self.clipLabel(shot: shot, index: index),
                                                    idempotencyKey: operationID)
                }
            } catch {
                // The marker exists for an UNKNOWN outcome: a lost response may
                // already count a clip, so it stays and blocks a second POST. A
                // definitive refusal is the opposite case — the server answered,
                // nothing was admitted or charged — and keeping the marker only
                // locked Generate behind "submission needs review" (TestFlight 59:
                // every preset reel was refused with 400 and the button stayed
                // dead). A 409 duplicate can mean this same operation already
                // started. Conflicts, transport errors, timeouts and 5xx keep it.
                if Self.isDefinitiveRefusal(error) { submission.clear() }
                throw error
            }
            let pending = PendingReelRequest(context: recoveryContext, photoNumber: index + 1, job: job,
                operationID: operationID, inputDigest: digest, submissionUnconfirmed: false,
                sourceJPEGBase64: jpeg.base64EncodedString(), sourceSpaceType: spaceType, qualityAttempt: attempt, framing: framing, outputAspect: aspect, sourceAssetID: sourceAssetID, photoProvenanceID: photoProvenanceID)
            try pending.save()
            do {
                let clip = try await retrieveClip(job: job, pending: pending, api: api, into: dir, index: index,
                                                 clearReceiptOnDownload: false, requireCurrent: requireCurrent)
                try await requireCurrent()
                return try await acknowledgeRecoveredClip(clip, request: pending, requireCurrent: requireCurrent)
            } catch let refusal as ReelQualityRefusal where refusal.mayRetry && attempt == 0 {
                try await requireCurrent()
                // This is an explicit terminal judgement, never a dropped response.
                // Keep the first accepted receipt until the next intent is atomically
                // saved above; no gap permits a second unknown submission.
                continue
            }
        }
        throw AIImagePrep.error("The quality check requested more than one retry. The saved request has been kept.")
    }

    nonisolated private static func preparedReelJPEG(photo: EnhancedPhoto, aspect: String) throws -> Data {
        try PhotoVersionHistory.requireReelReview(imageURL: photo.enhancedURL)
        guard let ui = UIImage(contentsOfFile: photo.enhancedURL.path) else { throw AIImagePrep.error("Couldn't read that photo.") }
        let scaled = AIImagePrep.downscaled(AIImagePrep.reelSource(ui, aspect: aspect), maxDimension: 2048)
        guard let jpeg = scaled.jpegData(compressionQuality: 0.95), !jpeg.isEmpty else { throw AIImagePrep.error("Couldn't prepare that photo.") }
        try VideoPreparedSourcePolicy.requireUsableJPEG(jpeg, aspect: aspect)
        return jpeg
    }

    /// The clip and batch position are durable BEFORE the exact accepted receipt
    /// is acknowledged. A repeated acknowledgement reuses its recorded clip.
    nonisolated private static func acknowledgeRecoveredClip(_ clip: URL, request: PendingReelRequest,
        requireCurrent: @MainActor @Sendable () throws -> Void) async throws -> URL {
        try await requireCurrent()
        guard PendingReelRequest.load(request.context)?.job.requestId == request.job.requestId else { throw CancellationError() }
        var batch = try PendingReelBatch.load(request.context)
        if let saved = batch {
            guard (1...saved.photos.count).contains(request.photoNumber),
                  saved.photos[request.photoNumber - 1].jpegBase64 == request.sourceJPEGBase64,
                  saved.completedPaths.count == request.photoNumber - 1 || saved.completedPaths.count == request.photoNumber else {
                throw AIImagePrep.error("The recovered photo does not match saved video progress. Its request has been kept.")
            }
            if saved.completedPaths.count == request.photoNumber {
                try await requireCurrent()
                request.clear()
                return FileStore.url(fromRelativePath: saved.completedPaths[request.photoNumber - 1])
            }
        }
        let retained = try retainRecoveredClip(clip, for: request.context.listingID)
        try await requireCurrent()
        if batch != nil {
            // Source identity is retained in the same atomic write as the clip,
            // before the accepted request can be acknowledged and removed.
            let position = request.photoNumber - 1, photo = batch!.photos[position]
            let source = ListingVideoSource(photoVersionID: photo.id,
                photoAssetID: request.sourceAssetID ?? photo.sourceAssetID,
                photoProvenanceID: request.photoProvenanceID ?? photo.photoProvenanceID,
                generationRequestID: request.job.requestId, generationProvenanceID: request.job.provenanceID,
                motionKind: OriginalPhotoMotion.isClip(retained) ? "original_photo" : "ai",
                sourceBound: request.job.sourceBound == true && request.job.sourceAssetID == (request.sourceAssetID ?? photo.sourceAssetID))
            if batch!.completedSources == nil && batch!.completedPaths.isEmpty { batch!.completedSources = [] }
            batch!.completedSources?.append(source)
            batch!.completedPaths.append(FileStore.relativePath(for: retained))
            try batch!.save()
        }
        try await requireCurrent()
        request.clear()
        return retained
    }

    /// Only an explicit choice after the original job's confirmed first retry
    /// verdict can send one safer POST or render the exact source locally.
    nonisolated private static func resolveSavedQualityRetry(_ request: PendingReelRequest, choice: ReelRecoveryChoice,
        api: APIClient, into dir: URL, requireCurrent: @MainActor @Sendable () throws -> Void) async throws -> URL {
        try await requireCurrent()
        try requireSavedReelReview(try PendingReelBatch.load(request.context))
        guard request.qualityAttempt == 0, request.submissionUnconfirmed != true,
              PendingReelRequest.load(request.context)?.job.requestId == request.job.requestId,
              let source = request.sourceJPEGBase64, let jpeg = Data(base64Encoded: source), !jpeg.isEmpty,
              let spaceType = request.sourceSpaceType else { throw AIImagePrep.error("Recover the saved request before choosing a safer retry.") }
        // Re-read the existing owned job and cached judgment. An unavailable
        // check or a changed session cannot open either fallback action.
        do {
            let already = try await retrieveClip(job: request.job, pending: request, api: api, into: dir,
                index: request.photoNumber - 1, requireCurrent: requireCurrent)
            return try await acknowledgeRecoveredClip(already, request: request, requireCurrent: requireCurrent)
        } catch let refusal as ReelQualityRefusal where refusal.mayRetry {
            // The only case which permits the two explicit choices below.
        }
        try await requireCurrent()
        guard PendingReelRequest.load(request.context)?.job.requestId == request.job.requestId,
              let shape = UIImage(data: jpeg)?.size, shape.width > 0, shape.height > 0 else { throw CancellationError() }
        let batch = try PendingReelBatch.load(request.context)
        if let batch {
            guard batch.completedPaths.count == request.photoNumber - 1, request.photoNumber <= batch.photos.count,
                  batch.photos[request.photoNumber - 1].jpegBase64 == source,
                  batch.framing == request.framing,
                  request.outputAspect == nil || request.outputAspect == batch.aspect else { throw AIImagePrep.error("Saved reel progress does not match this photo. Your request has been kept.") }
        }
        let aspect = request.outputAspect ?? batch?.aspect ?? (shape.width < shape.height ? "9:16" : "16:9")
        if choice == .originalPhoto {
            let local = dir.appendingPathComponent("clip-photo-motion-\(request.photoNumber - 1).mp4")
            try await OriginalPhotoMotion.render(jpeg: jpeg,
                renderSize: aspect == "9:16" ? CGSize(width: 1080, height: 1920) : CGSize(width: 1920, height: 1080), output: local)
            try await requireCurrent()
            return try await acknowledgeRecoveredClip(local, request: request, requireCurrent: requireCurrent)
        }
        let operationID = UUID().uuidString
        let digest = SHA256.hash(data: jpeg + Data("push_in|\(aspect)|\(request.photoNumber)|retry-1|\(request.framing ?? "legacy")".utf8)).map { String(format: "%02x", $0) }.joined()
        let submission = PendingReelRequest(context: request.context, photoNumber: request.photoNumber,
            job: AIVideoJob(requestId: operationID, statusUrl: "", responseUrl: "", kind: "reel"), operationID: operationID,
            inputDigest: digest, submissionUnconfirmed: true, sourceJPEGBase64: source, sourceSpaceType: spaceType, qualityAttempt: 1, framing: request.framing, outputAspect: aspect, sourceAssetID: request.sourceAssetID, photoProvenanceID: request.photoProvenanceID)
        try submission.save()
        try await requireCurrent()
        let job: AIVideoJob
        do {
            if let sourceAssetID = request.sourceAssetID {
                job = try await api.aiVideoReelClip(imageBase64: source, mime: "image/jpeg", prompt: nil, seconds: 5,
                    aspect: aspect, framing: request.framing, presetVersion: 1, motion: "push_in", room: batch?.photos[request.photoNumber - 1].shot?.room,
                    shotIndex: request.photoNumber - 1, shotCount: batch?.photos.count ?? request.photoNumber,
                    listingServerID: request.context.serverListingID, label: "Reel shot \(request.photoNumber) — safer retry", idempotencyKey: operationID,
                    sourceAssetID: sourceAssetID, sourceProvenanceID: request.photoProvenanceID)
            } else {
                job = try await api.aiVideoReelClip(imageBase64: source, mime: "image/jpeg", prompt: nil, seconds: 5,
                    aspect: aspect, framing: request.framing, presetVersion: 1, motion: "push_in", room: batch?.photos[request.photoNumber - 1].shot?.room,
                    shotIndex: request.photoNumber - 1, shotCount: batch?.photos.count ?? request.photoNumber,
                    listingServerID: request.context.serverListingID, label: "Reel shot \(request.photoNumber) — safer retry", idempotencyKey: operationID)
            }
        } catch {
            if Self.isDefinitiveRefusal(error), PendingReelRequest.load(request.context)?.job.requestId == operationID {
                // Restore the confirmed rejected job atomically, with no empty
                // interval that could invite a third unknown submission.
                try request.save()
            }
            throw error
        }
        let accepted = PendingReelRequest(context: request.context, photoNumber: request.photoNumber, job: job,
            operationID: operationID, inputDigest: digest, submissionUnconfirmed: false,
            sourceJPEGBase64: source, sourceSpaceType: spaceType, qualityAttempt: 1, framing: request.framing, outputAspect: aspect, sourceAssetID: request.sourceAssetID, photoProvenanceID: request.photoProvenanceID)
        try accepted.save()
        try await requireCurrent()
        let clip = try await retrieveClip(job: job, pending: accepted, api: api, into: dir,
            index: request.photoNumber - 1, requireCurrent: requireCurrent)
        return try await acknowledgeRecoveredClip(clip, request: accepted, requireCurrent: requireCurrent)
    }

    /// Resume the exact prepared source for each remaining position. Retained
    /// clips and their plan remain in order; a current receipt prevents any POST.
    nonisolated private static func completeSavedBatch(_ saved: PendingReelBatch, api: APIClient, into dir: URL,
        requireCurrent: @MainActor @Sendable () throws -> Void,
        progress: @MainActor @Sendable (Int) -> Void) async throws -> PendingReelBatch {
        try await requireCurrent()
        try requireSavedReelReview(saved)
        guard var batch = try PendingReelBatch.load(saved.context), batch.id == saved.id,
              !PendingReelRequest.exists(saved.context) else { throw AIImagePrep.error("Recover the saved photo before continuing this reel.") }
        while batch.completedPaths.count < batch.photos.count {
            try await requireCurrent()
            let index = batch.completedPaths.count, photo = batch.photos[index]
            guard let jpeg = Data(base64Encoded: photo.jpegBase64), !jpeg.isEmpty else { throw AIImagePrep.error("The saved source photo cannot be read. Your progress has been kept.") }
            await progress(index)
            let placeholder = dir.appendingPathComponent("saved-source-\(index).jpg")
            _ = try await makeClip(photo: EnhancedPhoto(id: photo.id, originalURL: placeholder, enhancedURL: placeholder),
                prompt: "", shot: photo.shot?.value, shotCount: batch.photos.count, motion: batch.scenePlanVersion == 1 ? photo.shot?.motion ?? batch.motion : batch.motion,
                aspect: batch.aspect, spaceType: batch.spaceType, api: api, listingServerID: batch.context.serverListingID,
                into: dir, index: index, recoveryContext: batch.context, requireCurrent: requireCurrent, preparedJPEG: jpeg, framing: batch.framing,
                sourceAssetID: photo.sourceAssetID, photoProvenanceID: photo.photoProvenanceID)
            try await requireCurrent()
            guard let updated = try PendingReelBatch.load(saved.context), updated.id == saved.id,
                  updated.completedPaths.count == index + 1 else { throw AIImagePrep.error("Reel progress could not be confirmed. Your clips have been kept.") }
            batch = updated
        }
        return batch
    }

    /// Give a downloaded clip an explicit media suffix before decoding it.
    /// A unique sibling avoids overwriting another file. If moving fails,
    /// AVFoundation can still try the original bytes; an empty frame check holds.
    nonisolated static func clipPath(forDownloaded downloaded: URL) -> URL {
        guard downloaded.pathExtension.lowercased() != "mp4" else { return downloaded }
        let renamed = downloaded.deletingLastPathComponent().appendingPathComponent("reel-download-\(UUID().uuidString).mp4")
        do { try FileManager.default.moveItem(at: downloaded, to: renamed) } catch { return downloaded }
        return renamed
    }

    /// A 4xx the server itself produced before admitting the request. 408 is a
    /// timeout and 409 can report an already-started operation, so neither is
    /// proof of non-admission. Everything 5xx or non-HTTP is also unknown.
    nonisolated private static func isDefinitiveRefusal(_ error: Error) -> Bool {
        guard let api = error as? APIError, let status = api.status else { return false }
        return (400...499).contains(status) && status != 408 && status != 409
    }

    /// A status poll that failed to get an answer, as opposed to an answer:
    /// transport loss, a timeout, or a 5xx/408/429 from the gateway. Anything
    /// definitive (a 4xx, an identity change, cancellation) is not.
    nonisolated static func isDroppedPoll(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if let url = error as? URLError { return url.code != .cancelled }
        if let api = error as? APIError, let status = api.status {
            return status >= 500 || status == 408 || status == 429
        }
        return false
    }

    nonisolated private static func retrieveClip(job: AIVideoJob, pending: PendingReelRequest?, api: APIClient,
        into dir: URL, index: Int, clearReceiptOnDownload: Bool = false,
        requireCurrent: @MainActor @Sendable () throws -> Void = { try Task.checkCancellation() }) async throws -> URL {
        guard pending?.submissionUnconfirmed != true else { throw AIImagePrep.error("That submission has no receipt to recover. Review it before generating again.") }
        let deadline = Date().addingTimeInterval(5 * 60)
        var remoteURL: URL?
        var droppedPolls = 0
        while remoteURL == nil {
            guard Date() < deadline else {
                throw AIImagePrep.error("The clip took too long.")
            }
            try await Task.sleep(nanoseconds: 5_000_000_000)
            try await requireCurrent()
            guard Date() < deadline else { throw AIImagePrep.error("The clip took too long.") }
            let status: AIVideoStatus
            do {
                status = try await api.aiVideoStatus(job)
                try await requireCurrent()
                guard Date() < deadline else { throw AIImagePrep.error("The clip took too long.") }
                droppedPolls = 0
            } catch where Self.isDroppedPoll(error) && droppedPolls < 5 {
                // The poll is read-only. A connection that dropped (the phone
                // was locked mid-clip, a cell handoff, a gateway 5xx) is not
                // an answer about the clip, so ask again. Six misses in a row
                // surface exactly as one did before; the paid receipt stays.
                droppedPolls += 1
                continue
            }
            switch status {
            case .processing:
                break   // keep polling — the caller shows "Clip X of N"
            case .completed(let videoURL):
                remoteURL = videoURL
            case .failed(let message):
                pending?.clear()
                throw AIImagePrep.error(message)
            }
        }
        guard let remoteURL else {
            throw AIImagePrep.error("The AI didn't return a clip.")
        }

        try await requireCurrent()
        let (downloaded, resp) = try await URLSession.shared.download(from: remoteURL)
        defer { try? FileManager.default.removeItem(at: downloaded) }
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AIImagePrep.error("Couldn't download the finished clip (HTTP \(http.statusCode)).")
        }
        try await requireCurrent()
        guard ((try? downloaded.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0 else {
            throw AIImagePrep.error("The completed clip was empty. Recover the saved request to download it again.")
        }
        // Use an explicit media suffix, but never treat that suffix as proof
        // the vendor returned a readable clip. The actual decoder and quality
        // gate below must still succeed before these bytes can be used.
        let tmp = Self.clipPath(forDownloaded: downloaded)
        defer { try? FileManager.default.removeItem(at: tmp) }
        // No unchecked clip enters the parked library or the final composition.
        // Recovery reuses the accepted generation receipt and exact source; it
        // never submits another paid clip. Legacy receipts without a source hold.
        guard let source = pending?.sourceJPEGBase64, !source.isEmpty,
              let spaceType = pending?.sourceSpaceType else {
            throw AIImagePrep.error("This older request has no saved source photo for its quality check. It has been kept, but cannot be added to a reel unchecked.")
        }
        let frames = await ClipFrames.extract(from: tmp)
        // FAIL CLOSED, locally: a clip this phone cannot read is held, the
        // receipt stays, and no empty judgement is sent to the server.
        guard !frames.isEmpty else {
            throw AIImagePrep.error("Couldn't read the finished clip on this phone, so it is being held rather than published. Recover the saved request to try again.")
        }
        try await requireCurrent()
        let verdict = try await api.aiVideoDrift(DriftCheckRequest(requestID: job.requestId,
            kind: "reel", sourceBase64: source, frames: frames, seconds: 5,
            spaceType: spaceType, listingServerID: pending?.context.serverListingID,
            provenanceID: job.provenanceID, sourceAssetID: pending?.sourceAssetID, attempt: pending?.qualityAttempt ?? 1))
        try await requireCurrent()
        guard verdict.mayUse else {
            guard verdict.status == .fail, verdict.action == "refuse",
                  let jpeg = Data(base64Encoded: source) else {
                throw ReelQualityRefusal(verdict: verdict)
            }
            // Only the server's terminal property-drift refusal permits this.
            // Decode, identity, quota, consent and unavailable-QC failures never
            // reach here. The rejected video is deleted by the existing defer.
            try await requireCurrent()
            let local = dir.appendingPathComponent("clip-photo-motion-\(index).mp4")
            let shape = UIImage(data: jpeg)?.size
            guard let shape, shape.width > 0, shape.height > 0 else { throw CocoaError(.fileReadCorruptFile) }
            let outputAspect = pending?.outputAspect ?? (shape.width < shape.height ? "9:16" : "16:9")
            let size = outputAspect == "9:16" ? CGSize(width: 1080, height: 1920) : CGSize(width: 1920, height: 1080)
            try await OriginalPhotoMotion.render(jpeg: jpeg, renderSize: size, output: local)
            try await requireCurrent()
            // Caller durably retains this local clip before retiring the failed
            // AI receipt. No provider call or cost-history mutation is made.
            return local
        }
        let dest = dir.appendingPathComponent("clip-\(index).mp4")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        if clearReceiptOnDownload { pending?.clear() }
        return dest
    }

    /// Recovery acknowledges only after the completed clip is retained and
    /// addressable. A full disk keeps its accepted receipt available to retry.
    nonisolated private static func retainRecoveredClip(_ clip: URL, for listingID: UUID) throws -> URL {
        let fm = FileManager.default
        let bytes = try clip.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard bytes > 0 else { throw AIImagePrep.error("The recovered clip is empty. Retry the saved request.") }
        let dir = PendingReelClips.directory(for: listingID)
        var relPaths = (try PendingReelClips.readRecord(for: listingID)?.clipURLs ?? []).map { FileStore.relativePath(for: $0) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let prefix = OriginalPhotoMotion.isClip(clip) ? "clip-photo-motion-" : "clip-recovered-"
        let dest = dir.appendingPathComponent("\(prefix)\(UUID().uuidString).mp4")
        do { try fm.moveItem(at: clip, to: dest) }
        catch { try fm.copyItem(at: clip, to: dest) }
        relPaths.append(FileStore.relativePath(for: dest))
        try PendingReelClips(listingID: listingID, savedAt: Date(), relPaths: relPaths).saveDurably()
        guard PendingReelClips.load(for: listingID)?.clipURLs.contains(dest) == true,
              (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize) == bytes else {
            throw AIImagePrep.error("Couldn't retain the recovered clip. Free some space and retry the saved request.")
        }
        return dest
    }

    // MARK: Stitch (now Render/ReelComposer.swift)

    /// Caption text with fallbacks so an empty/unfilled listing can never render
    /// a blank title card: no address → a generic hook; degenerate "0 bd · 0 ba"
    /// facts → the tagline instead → or no second line at all.
    nonisolated private static func reelCaptions(for listing: Listing) -> ReelCaptions {
        let address = listing.address.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = address.isEmpty ? "Come take the tour" : address
        let hasFacts = listing.beds > 0 || listing.baths > 0 || listing.sqft > 0
        let facts = hasFacts ? listing.metaLine : ""
        let tagline = (listing.tagline ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return ReelCaptions(title: title,
                            subtitle: facts.isEmpty ? tagline : facts,
                            watermark: "Made with Rendprop")
    }

    /// Turn the reel's clips into `ReelComposer.Shot`s.
    ///
    /// THE NO-REGRESSION RULE LIVES HERE. With no shot plan every shot is
    /// `Shot(url:)` and nothing else — the clip's own length, 1×, no caption —
    /// which is exactly the reel this screen made before the composer existed.
    /// A plan only ever ADDS: it can shorten a detail, hold a hero, and put three
    /// words on screen. It can never lengthen the reel beyond the clips, because
    /// `seconds` is capped at the clip's own length times the slowest rate the
    /// composer will allow.
    ///
    /// The extra clips (the aerial intro) lead the reel and are deliberately NOT
    /// paced or captioned: an establishing shot is the one shot that should just
    /// play, and the plan's shots are indexed against the PHOTOS.
    ///
    /// `nonisolated` and pure — value types in, value types out.
    nonisolated private static func shots(extras: [URL], photoClips: [URL],
                                          plan: [AIShot?], captionsOn: Bool) -> [ReelComposer.Shot] {
        var out: [ReelComposer.Shot] = extras.map { ReelComposer.Shot(url: $0) }
        for (i, url) in photoClips.enumerated() {
            // The plan is matched BY POSITION, not by photo id: a clip that
            // failed to generate is simply absent from `photoClips`, and after
            // that the ids and the positions disagree. The caller therefore
            // hands us one entry per CLIP, in clip order, holding nil where a
            // photo had no plan (see `generate()`).
            let shot: AIShot? = i < plan.count ? plan[i] : nil
            // Bounded against the clip we actually bought. Every photo clip is
            // generated at a fixed 5 s, so a plan is allowed to tighten a detail
            // to 3 s or hold a hero to 8 s and no further: below 3 s a shot is a
            // flash frame, and past 8 s a 5 s clip is being slowed enough to
            // judder. The bound also keeps the reel's total length close to the
            // `target_seconds` the script was written to fit — a plan that
            // silently halved the reel would leave the voiceover overrunning it.
            var seconds: Double? = nil
            if let raw = shot?.seconds, raw.isFinite {
                seconds = min(clipHoldSeconds, max(clipTrimSeconds, raw))
            }
            out.append(ReelComposer.Shot(url: url,
                                         seconds: seconds,
                                         speed: nil,
                                         caption: captionsOn ? shot?.onScreenText : nil))
        }
        return out
    }

    /// The plan entry written for THIS photo. BY ID ONLY, never by position —
    /// the same rule the server applies to the model's own answer
    /// (COPY-ASSIST-CONTRACT §4.5). If a plan named five of six photos, position
    /// matching would hand the sixth a caption and a camera move written for a
    /// different room and the reel would confidently narrate the wrong picture.
    /// A photo with no entry simply plays as it always did.
    nonisolated private static func shot(for photo: EnhancedPhoto,
                                         in plan: [AIShot]) -> AIShot? {
        plan.first(where: { $0.photoID == photo.id })
    }

    /// The provenance label a broker reads in the audit log. "Reel clip 3" is a
    /// row number; "Kitchen — reel shot 3 of 6" is a sentence about a property.
    /// Falls back to the old wording when the plan named no room, so nothing that
    /// already shipped changes shape.
    nonisolated private static func clipLabel(shot: AIShot?, index: Int) -> String {
        if let room = shot?.room?.trimmingCharacters(in: .whitespacesAndNewlines), !room.isEmpty {
            return String("\(room) — reel shot \(index + 1)".prefix(80))
        }
        return "Reel clip \(index + 1)"
    }

    /// Ask for the reel's edit. NEVER THROWS: a shot plan is an upgrade, not a
    /// dependency, and a copy route that is down, refused (fair housing), slow or
    /// unreachable must not stand between the agent and a reel he is paying for.
    /// An empty result puts every downstream decision back exactly where it was
    /// before this route existed.
    ///
    /// `{address}` is resolved HERE, on the device, in every piece of text the
    /// server wrote — the server never learns the street address (see
    /// `AICopyFacts`), so this is the only place the property gets its name back.
    ///
    /// The SPOKEN line is substituted, exactly as the script route's already is.
    /// A CAPTION carrying the token is DROPPED instead (COPY-ASSIST-CONTRACT
    /// §4.4): burned-in text is legible and held for the whole shot, so an
    /// address across the frame is worse than one merely spoken, and leaving the
    /// token would put the literal word "{address}" on the video. The server
    /// already refuses to write one — this is the client half of the same rule,
    /// so a server bug cannot put a street address on somebody's reel.
    nonisolated private static func planShots(_ request: AIShotListRequest, api: APIClient,
                                              address: String, fallbackNoun: String) async -> [AIShot] {
        do {
            let result = try await api.aiCopyShotlist(request)
            return result.shots.map { shot in
                let caption = shot.onScreenText.flatMap { text -> String? in
                    text.contains(addressToken) ? nil : text
                }
                return AIShot(photoID: shot.photoID,
                              order: shot.order,
                              motion: shot.motion,
                              room: shot.room,
                              onScreenText: caption,
                              seconds: shot.seconds,
                              voiceLine: shot.voiceLine.map {
                                  Self.filledAddress($0, address: address, fallbackNoun: fallbackNoun)
                              })
            }
        } catch {
            return []
        }
    }

    /// Put the reel's photos in the order the PLANNER asked for.
    ///
    /// The plan opens on the best establishing shot and closes on the best CTA
    /// frame; tap order is only its tiebreak. Keeping tap order would leave the
    /// closing caption ("BOOK YOUR SHOWING") on whichever picture happened to be
    /// tapped last — the words would still be on the right photo, just in the
    /// wrong place in the reel.
    ///
    /// STRICTLY ALL OR NOTHING. If the plan does not name each photo exactly once
    /// the tap order is kept untouched: a partial reorder is worse than none, and
    /// no photo the agent picked may be lost or repeated by an edit decision.
    nonisolated private static func reordered(_ photos: [EnhancedPhoto],
                                              by plan: [AIShot]) -> [EnhancedPhoto] {
        guard plan.count == photos.count, !plan.isEmpty else { return photos }
        var byID: [String: EnhancedPhoto] = [:]
        for photo in photos { byID[photo.id] = photo }
        guard byID.count == photos.count else { return photos }   // duplicate ids — leave it alone
        var out: [EnhancedPhoto] = []
        for shot in plan {
            guard let photo = byID.removeValue(forKey: shot.photoID) else { return photos }
            out.append(photo)
        }
        return out.count == photos.count ? out : photos
    }

    /// Build the shot-list request from the listing: the same facts
    /// `/ai-copy/script` gets, plus the photos in the order they were tapped.
    ///
    /// THE STREET ADDRESS IS NOT IN HERE AND MUST NEVER BE — `AICopyFacts` has no
    /// field that could carry one, and the name goes back in on this device in
    /// `filledAddress`.
    ///
    /// NO WALK ORDER, deliberately. `/ai-copy/script` takes `room_tags` because a
    /// script follows the tour; `/ai-copy/shotlist` takes an area PER PHOTO
    /// (`Photo.room`) because a shot list has to know what THIS picture shows. A
    /// `RoomTag` is a timestamp on the walkthrough VIDEO and an `EnhancedPhoto`
    /// is an id and two file URLs — there is no honest mapping between them, so
    /// this sends no rooms at all rather than a plausible-looking wrong one. The
    /// planner keeps tap order for unlabelled photos, which is the right answer
    /// when nobody knows better. `Photo.room` is there for the day a photo
    /// carries its own area tag.
    ///
    /// `nonisolated` and pure: value types in, value type out.
    nonisolated private static func shotlistRequest(for listing: Listing, space: SpaceType,
                                                    photos: [EnhancedPhoto],
                                                    targetSeconds: Int,
                                                    tone: String) -> AIShotListRequest {
        // One source of truth for the facts: whatever the script route sends, the
        // shot planner sends, so the two can never describe different properties.
        let script = Self.scriptRequest(for: listing, space: space, roomTags: [],
                                        photoCount: photos.count, targetSeconds: targetSeconds,
                                        tone: tone)
        return AIShotListRequest(listingServerID: script.listingServerID,
                                 spaceType: script.spaceType,
                                 facts: script.facts,
                                 photos: photos.map { AIShotListRequest.Photo(id: $0.id, room: nil) },
                                 targetSeconds: script.targetSeconds,
                                 tone: script.tone)
    }
}


// MARK: - Pickers

// MARK: - Floor plan (Apple RoomPlan → USDZ "dollhouse")
// LiDAR-only (iPhone/iPad Pro). Scans room after room in ONE AR session, merges
// them with RoomPlan's StructureBuilder (iOS 17+, and it handles rooms on
// different storeys), exports USDZ, and previews it with QuickLook.
// Per-listing file in Documents/FloorPlans/.

struct FloorPlanView: View {
    let listing: Listing
    @EnvironmentObject private var model: AppModel

    @State private var showScanner = false
    @State private var showViewer = false       // 3D / AR (USDZ via QuickLook)
    @State private var showPlan2D = false        // flat top-down 2D plan
    @State private var showImporter = false      // PDF/image blueprint picker
    @State private var showUpload = false        // view the uploaded blueprint
    @State private var planExists = false        // USDZ present
    @State private var plan2DExists = false      // JSON geometry present (new scans)
    @State private var uploadedURL: URL?         // uploaded PDF/image blueprint, if any
    @State private var importError: String?
    /// A re-scan replaces the saved plan — ask first (F-A-17).
    @State private var showRescanConfirm = false
    /// Set when "3D" is tapped inside the 2D plan: the second cover can only be
    /// presented once the first has finished dismissing, so it is opened from
    /// the 2D cover's `onDismiss` rather than in the same event (F-A-17).
    @State private var openViewerAfter2D = false

    private var floorPlanDir: URL {
        let dir = FileStore.documents.appendingPathComponent("FloorPlans", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var usdzURL: URL {
        floorPlanDir.appendingPathComponent("\(listing.id.uuidString).usdz")
    }

    /// CapturedRoom geometry saved alongside the USDZ — powers the 2D plan.
    private var planJSONURL: URL {
        usdzURL.deletingPathExtension().appendingPathExtension("json")
    }

    /// An uploaded blueprint is stored as `<listing.id>-upload.<ext>` (pdf/png/jpg…).
    private func existingUpload() -> URL? {
        let prefix = "\(listing.id.uuidString)-upload"
        let items = (try? FileManager.default.contentsOfDirectory(
            at: floorPlanDir, includingPropertiesForKeys: nil)) ?? []
        return items.first { $0.deletingPathExtension().lastPathComponent == prefix }
    }

    private func refreshState() {
        planExists = FileManager.default.fileExists(atPath: usdzURL.path)
        plan2DExists = FileManager.default.fileExists(atPath: planJSONURL.path)
        uploadedURL = existingUpload()
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let picked = urls.first else {
            if case .failure(let err) = result { importError = err.localizedDescription }
            return
        }
        let scoped = picked.startAccessingSecurityScopedResource()
        defer { if scoped { picked.stopAccessingSecurityScopedResource() } }
        let ext = picked.pathExtension.isEmpty ? "pdf" : picked.pathExtension.lowercased()
        // Clear any previous upload, then copy the new file in.
        if let old = existingUpload() { try? FileManager.default.removeItem(at: old) }
        let dest = floorPlanDir.appendingPathComponent("\(listing.id.uuidString)-upload.\(ext)")
        do {
            try FileManager.default.copyItem(at: picked, to: dest)
            refreshState()
        } catch {
            importError = error.localizedDescription
        }
    }

    /// Upload-a-blueprint section — shown in both the LiDAR and no-LiDAR paths.
    @ViewBuilder private var uploadSection: some View {
        if let uploadedURL {
            VStack(spacing: 6) {
                Image(systemName: "doc.richtext")
                    .font(.system(size: 30, weight: .light)).foregroundStyle(Theme.accent)
                Text("Blueprint uploaded").font(.rpHeadline).foregroundStyle(Theme.ink)
                Text(uploadedURL.lastPathComponent)
                    .font(.rpCaption).foregroundStyle(Theme.inkDim).lineLimit(1)
            }
            .frame(maxWidth: .infinity).padding(.top, 6)
            primaryButton("View blueprint", "doc.text.magnifyingglass") { showUpload = true }
            secondaryButton("Replace blueprint", "arrow.triangle.2.circlepath") { showImporter = true }
            ShareLink(item: uploadedURL) {
                Label("Share blueprint", systemImage: "square.and.arrow.up")
                    .font(.rpBody.weight(.semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 13)
                    .modifier(RendpropActionLabelSurface(primary: false))
            }
        } else {
            secondaryButton("Upload floor plan (PDF or image)", "square.and.arrow.up.on.square") {
                showImporter = true
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                Text("Choose a phone scan, your own measurements, or an existing plan.")
                    .font(.rpBody).foregroundStyle(Theme.inkDim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if RoomCaptureSession.isSupported {
                    VStack(spacing: 10) {
                        Image(systemName: planExists ? "cube.fill" : "cube.transparent")
                            .font(.system(size: 44, weight: .light))
                            .foregroundStyle(Theme.accent)
                        Text(planExists ? "Your room scan" : "Scan rooms with your phone")
                            .font(.rpTitle)
                            .foregroundStyle(Theme.ink)
                        // TRUE copy (F-A-17): say what the scanner actually does.
                        // It now walks room by room in one session and RoomPlan
                        // merges them — including across storeys — but it is still
                        // a phone scan, not a survey, and a new scan replaces the
                        // old one. Never promise more than that.
                        Text(planExists
                             ? "What you scanned, as a flat top-down plan or in 3D. Scanning again replaces it."
                             : "Walk each room slowly with your phone, tap Finish room, then walk to the next one — upstairs too. Rendprop draws them as one plan.")
                            .font(.rpBody).foregroundStyle(Theme.inkDim)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)

                    if planExists {
                        if plan2DExists {
                            primaryButton("View floor plan", "map") { showPlan2D = true }
                            secondaryButton("View in 3D", "rotate.3d") { showViewer = true }
                        } else {
                            // Older scan: only the 3D model was saved. Re-scan for the flat plan.
                            primaryButton("View in 3D", "rotate.3d") { showViewer = true }
                            Text("Scan again to generate the flat 2D plan.")
                                .font(.rpCaption).foregroundStyle(Theme.inkDim)
                                .multilineTextAlignment(.center)
                        }
                        // Destructive: a successful re-scan overwrites the saved
                        // USDZ + geometry, so confirm first (F-A-17).
                        secondaryButton("Scan again", "arrow.triangle.2.circlepath") { showRescanConfirm = true }
                        ShareLink(item: usdzURL) {
                            Label("Share the 3D model", systemImage: "square.and.arrow.up")
                                .font(.rpBody.weight(.semibold))
                                .frame(maxWidth: .infinity).padding(.vertical, 13)
                                .modifier(RendpropActionLabelSurface(primary: false))
                        }
                        if plan2DExists {
                            Text(listing.spaceType == .realEstate
                                 ? "Open the floor plan to export each floor as an image for a listing or a flyer."
                                 : "Open the floor plan to export each floor as an image for your website or a flyer.")
                                .font(.rpCaption).foregroundStyle(Theme.inkDim)
                                .multilineTextAlignment(.center)
                        }
                    } else {
                        primaryButton("Start scan", "cube.transparent") { showScanner = true }
                    }

                } else {
                    VStack(spacing: 10) {
                        Label("Phone scanning needs LiDAR", systemImage: "camera.viewfinder")
                            .font(.rpHeadline)
                            .foregroundStyle(Theme.ink)
                        Text("This device cannot scan rooms automatically. You can still enter measurements or upload a floor plan below.")
                            .font(.rpBody).foregroundStyle(Theme.inkDim)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
                }
                Divider().padding(.vertical, 6)
                measurementsSection
                Divider().padding(.vertical, 6)
                VStack(alignment: .leading, spacing: 10) {
                    Label("Upload an existing plan", systemImage: "doc.richtext")
                        .font(.rpHeadline).foregroundStyle(Theme.ink)
                    Text("Keep a PDF or image from your measuring software with this listing.")
                        .font(.rpCaption).foregroundStyle(Theme.inkDim)
                    uploadSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
        }
        .background(Theme.bg)
        .navigationTitle("Floor plans & measurements")
        .navigationBarTitleDisplayMode(.inline)
        .askAI(.floorPlan, listingID: listing.id)
        .onAppear { refreshState() }
        .fullScreenCover(isPresented: $showScanner) {
            RoomScanView(exportURL: usdzURL) { url in
                showScanner = false
                refreshState()
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $showViewer) {
            NavigationStack {
                USDZQuickLook(url: usdzURL)
                    .ignoresSafeArea()
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showViewer = false }
                        }
                    }
            }
        }
        .fullScreenCover(isPresented: $showPlan2D, onDismiss: {
            // Presenting the 3D cover in the SAME event that dismisses this one
            // silently dropped it — chain it off the dismissal instead (F-A-17).
            if openViewerAfter2D {
                openViewerAfter2D = false
                showViewer = true
            }
        }) {
            NavigationStack {
                FloorPlan2DView(jsonURL: planJSONURL, address: listing.address)
                    .navigationTitle("Floor plan")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showPlan2D = false }
                        }
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                openViewerAfter2D = true
                                showPlan2D = false
                            } label: {
                                Label("3D", systemImage: "rotate.3d")
                            }
                        }
                    }
            }
        }
        .confirmationDialog("Scan this place again?", isPresented: $showRescanConfirm,
                            titleVisibility: .visible) {
            Button("Scan again", role: .destructive) {
                // Present the scanner AFTER this dialog has finished dismissing —
                // a cover raised inside the dismissing event gets swallowed (the
                // same reason the wand→staging dialog hops a runloop).
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { showScanner = true }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A finished scan replaces the plan you have now, every floor of it. Export or share the current one first if you want to keep it.")
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.pdf, .image],
                      allowsMultipleSelection: false) { result in
            handleImport(result)
        }
        .fullScreenCover(isPresented: $showUpload) {
            if let uploadedURL {
                NavigationStack {
                    // QuickLook renders PDFs and images flat (no AR) — reused here.
                    USDZQuickLook(url: uploadedURL)
                        .ignoresSafeArea()
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { showUpload = false }
                            }
                        }
                }
            }
        }
        .alert("Couldn't add that file",
               isPresented: Binding(get: { importError != nil },
                                    set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    private var measurementsSection: some View {
        let current = model.listings.first(where: { $0.id == listing.id }) ?? listing
        let count = current.floorMeasurements?.rooms.count ?? 0
        let outlineCount = current.floorMeasurements?.outlines.count ?? 0
        return VStack(alignment: .leading, spacing: 12) {
            Label("Measurements", systemImage: "ruler")
                .font(.rpTitle).foregroundStyle(Theme.ink)
            Text("Enter room dimensions or draw the home's wall outline. Review areas in the worksheet and download a plan. Furnished rooms work too.")
                .font(.rpBody).foregroundStyle(Theme.inkDim)
            NavigationLink {
                FloorMeasurementsView(listing: current)
            } label: {
                Label(outlineCount > 0 ? "Open measurements · \(outlineCount) outlines" : count == 0 ? "Enter measurements" : "Open measurements · \(count) rooms", systemImage: "ruler")
                    .font(.rpBody.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 14)
                    .modifier(RendpropActionLabelSurface(primary: true))
            }.accessibilityIdentifier("floorPlan.measurements")
        }.padding().background(Theme.card).clipShape(RoundedRectangle(cornerRadius: Theme.radius))
    }

    private func primaryButton(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.rpBody.weight(.semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .modifier(RendpropActionLabelSurface(primary: true))
        }
    }
    private func secondaryButton(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.rpBody.weight(.semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 13)
                .background(Theme.fillSubtle).foregroundStyle(Theme.ink)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

// MARK: - What a finished floor-plan scan saves

/// The geometry saved next to the exported USDZ.
///
/// A scan used to be one room, stored as a bare `CapturedRoom`. It can now be a
/// whole building — several rooms across several storeys, captured in one
/// continuous AR session and merged by RoomPlan's own `StructureBuilder` — so the
/// on-disk shape is an array. `load` still reads the old single-room files, so a
/// plan scanned before this build keeps working and never needs re-scanning.
struct SavedFloorPlan: Codable {
    var rooms: [CapturedRoom]

    static func load(from url: URL) -> SavedFloorPlan? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        if let many = try? dec.decode(SavedFloorPlan.self, from: data) { return many }
        // Pre-multi-room file: a bare CapturedRoom at the top level.
        if let one = try? dec.decode(CapturedRoom.self, from: data) { return SavedFloorPlan(rooms: [one]) }
        return nil
    }

    /// One entry per storey, lowest first. RoomPlan works out which floor each room
    /// is on by itself (`CapturedRoom.story`) — we only have to group by it, because
    /// two floors drawn on one page would print the upstairs on top of the
    /// downstairs. On iOS 16 there is no `story`, so everything is one floor.
    var storeys: [Storey] {
        if #available(iOS 17.0, *) {
            var byStory: [Int: [CapturedRoom]] = [:]
            for r in rooms { byStory[r.story, default: []].append(r) }
            let keys = byStory.keys.sorted()
            return keys.map { Storey(id: $0, rooms: byStory[$0] ?? [], isOnlyStorey: keys.count == 1) }
        } else {
            return rooms.isEmpty ? [] : [Storey(id: 0, rooms: rooms, isOnlyStorey: true)]
        }
    }

    struct Storey: Identifiable {
        let id: Int             // RoomPlan's story number: 0 = the floor you started on
        let rooms: [CapturedRoom]
        let isOnlyStorey: Bool

        /// US convention — RoomPlan's story 0 is the floor the scan started on, which
        /// for a walk-in front door is the 1st floor.
        var name: String {
            switch id {
            case 0:  return "1st floor"
            case 1:  return "2nd floor"
            case 2:  return "3rd floor"
            case -1: return "Basement"
            case let n where n > 2:  return "\(n + 1)th floor"
            default: return "Level \(id)"
            }
        }
    }
}

/// Hosts RoomPlan's scanning UI + Cancel/Finish, and — on iOS 17 and later — lets a
/// person scan room after room in ONE AR session and merges them into a single
/// structure before exporting the USDZ.
struct RoomScanView: UIViewControllerRepresentable {
    let exportURL: URL
    let onFinish: (URL?) -> Void

    func makeUIViewController(context: Context) -> RoomScanController {
        let c = RoomScanController(exportURL: exportURL)
        c.onFinish = onFinish
        return c
    }
    func updateUIViewController(_ uiViewController: RoomScanController, context: Context) {}
}

final class RoomScanController: UIViewController, RoomCaptureViewDelegate {
    private let roomCaptureView = RoomCaptureView(frame: .zero)
    private let config = RoomCaptureSession.Configuration()
    private var isScanning = false
    /// Every room captured so far in THIS session. One entry means the old
    /// single-room behaviour, exactly as before.
    private var rooms: [CapturedRoom] = []
    /// Set while RoomPlan is turning the raw scan into a `CapturedRoom`, so the
    /// buttons can't be tapped into a bad state mid-processing.
    private var isProcessing = false
    private var isFinishing = false
    let exportURL: URL
    var onFinish: ((URL?) -> Void)?

    /// Multi-room merging is `StructureBuilder`, which is iOS 17+. The app still
    /// deploys to iOS 16, where a scan stays exactly one room.
    private var supportsMultiRoom: Bool {
        if #available(iOS 17.0, *) { return true }
        return false
    }

    // UI
    private let cancelButton = UIButton(type: .system)
    private let secondaryButton = UIButton(type: .system)   // "Scan the next room"
    private let primaryButton = UIButton(type: .system)     // "Finish room" / "Done"
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)

    init(exportURL: URL) {
        self.exportURL = exportURL
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        roomCaptureView.translatesAutoresizingMaskIntoConstraints = false
        roomCaptureView.delegate = self
        view.addSubview(roomCaptureView)

        style(cancelButton, "Cancel", filled: false, action: #selector(cancelTapped))
        style(secondaryButton, "Scan the next room", filled: false, action: #selector(nextRoomTapped))
        style(primaryButton, "Finish room", filled: true, action: #selector(primaryTapped))

        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.textColor = .white
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 2
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.layer.shadowColor = UIColor.black.cgColor
        statusLabel.layer.shadowOpacity = 0.7
        statusLabel.layer.shadowRadius = 3
        statusLabel.layer.shadowOffset = .zero
        view.addSubview(statusLabel)

        spinner.color = .white
        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)

        let row = UIStackView(arrangedSubviews: [cancelButton, secondaryButton, primaryButton])
        row.axis = .horizontal
        row.spacing = 10
        row.distribution = .fillEqually
        row.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(row)

        NSLayoutConstraint.activate([
            roomCaptureView.topAnchor.constraint(equalTo: view.topAnchor),
            roomCaptureView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            roomCaptureView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            roomCaptureView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            row.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            row.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            row.heightAnchor.constraint(equalToConstant: 50),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            statusLabel.bottomAnchor.constraint(equalTo: row.topAnchor, constant: -12),
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -10),
        ])
        refreshControls()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard !isScanning, rooms.isEmpty else { return }
        roomCaptureView.captureSession.run(configuration: config)
        isScanning = true
        refreshControls()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isScanning { roomCaptureView.captureSession.stop(); isScanning = false }
    }

    // MARK: Buttons

    private func refreshControls() {
        let n = rooms.count
        cancelButton.isHidden = isProcessing || isFinishing
        if isProcessing || isFinishing {
            secondaryButton.isHidden = true
            primaryButton.isHidden = true
            spinner.startAnimating()
            statusLabel.text = isFinishing
                ? "Putting the rooms together…"
                : "Finishing this room…"
            return
        }
        spinner.stopAnimating()
        if rooms.isEmpty, !isScanning {
            // viewDidLoad has run but viewWillAppear hasn't started the session yet.
            secondaryButton.isHidden = true
            primaryButton.isHidden = true
            statusLabel.text = "Starting the scanner…"
            return
        }
        if isScanning {
            secondaryButton.isHidden = true
            primaryButton.isHidden = false
            primaryButton.setTitle(n == 0 ? "Finish room" : "Finish room \(n + 1)", for: .normal)
            statusLabel.text = n == 0
                ? "Walk the room slowly and point the phone at every wall."
                : "Room \(n) saved. Walk this one the same way."
        } else {
            // A room has just been captured. Offer another, or stop here.
            secondaryButton.isHidden = !supportsMultiRoom
            primaryButton.isHidden = false
            primaryButton.setTitle(n <= 1 ? "Done" : "Done — \(n) rooms", for: .normal)
            statusLabel.text = supportsMultiRoom
                ? "\(n) room\(n == 1 ? "" : "s") scanned. To add another, keep the phone up and walk there — including up or down stairs. Don't lock the screen."
                : "Room scanned."
        }
    }

    @objc private func primaryTapped() {
        if isScanning {
            // Stop THIS room but keep the AR session alive: RoomPlan can only merge
            // rooms that share one world coordinate space, and pausing the AR session
            // is what throws that space away. `stop(pauseARSession:)` is iOS 17+.
            isScanning = false
            isProcessing = true
            refreshControls()
            if #available(iOS 17.0, *) {
                roomCaptureView.captureSession.stop(pauseARSession: false)
            } else {
                roomCaptureView.captureSession.stop()
            }
        } else {
            finish()
        }
    }

    @objc private func nextRoomTapped() {
        guard supportsMultiRoom, !isScanning, !isProcessing, !isFinishing else { return }
        roomCaptureView.captureSession.run(configuration: config)
        isScanning = true
        refreshControls()
    }

    @objc private func cancelTapped() {
        if isScanning {
            roomCaptureView.captureSession.stop()
            isScanning = false
        }
        onFinish?(nil)
    }

    // MARK: RoomCaptureViewDelegate

    // Let RoomPlan process the scan into a final result.
    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool { true }

    func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        isProcessing = false
        rooms.append(processedResult)
        // One room and no way to add another (iOS 16): behave exactly as before and
        // finish immediately, so nothing about the old flow changes on old systems.
        if !supportsMultiRoom {
            finish()
            return
        }
        refreshControls()
    }

    // MARK: Finishing

    private func finish() {
        guard !isFinishing else { return }
        guard !rooms.isEmpty else { onFinish?(nil); return }
        isFinishing = true
        refreshControls()

        let captured = rooms
        let dest = exportURL
        Task { @MainActor in
            let ok = await Self.exportPlan(rooms: captured, to: dest)
            self.isFinishing = false
            self.onFinish?(ok ? dest : nil)
        }
    }

    /// Export the USDZ and save the geometry beside it. Returns false only if the
    /// USDZ itself could not be written — that is the file the rest of the screen
    /// keys off.
    private nonisolated static func exportPlan(rooms: [CapturedRoom], to dest: URL) async -> Bool {
        // RoomPlan refuses a USD filename whose first character is a digit before
        // iOS 17.4, and ours is a UUID — which starts with a digit about 40% of the
        // time. Export to a safe temporary name in the same folder and move it into
        // place, so the file we keep can still be named after the listing.
        let tmp = dest.deletingLastPathComponent()
            .appendingPathComponent("plan-\(UUID().uuidString).usdz")
        defer { try? FileManager.default.removeItem(at: tmp) }

        var exported = false
        if #available(iOS 17.0, *), rooms.count > 1 {
            do {
                let builder = StructureBuilder(options: [.beautifyObjects])
                let structure = try await builder.capturedStructure(from: rooms)
                try structure.export(to: tmp, exportOptions: .parametric)
                exported = true
            } catch {
                // The rooms didn't share a world space (tracking was lost between
                // them, or the app was backgrounded). Rather than lose the whole
                // scan, fall through and export the first room on its own.
                exported = false
            }
        }
        if !exported, let first = rooms.first {
            do {
                try first.export(to: tmp, exportOptions: .parametric)
                exported = true
            } catch {
                exported = false
            }
        }
        guard exported else { return false }

        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
        } catch {
            return false
        }

        // Persist the rooms so the flat 2D plan can be drawn (and re-drawn per
        // storey) without re-scanning.
        //
        // On a RE-SCAN the USDZ is replaced but the JSON write can still fail
        // (encode error, disk full). Drop the previous geometry FIRST, so the flat
        // plan can never show the OLD rooms beside the NEW 3D model; the screen then
        // honestly offers "re-scan for the 2D plan".
        let jsonURL = dest.deletingPathExtension().appendingPathExtension("json")
        try? FileManager.default.removeItem(at: jsonURL)
        if let data = try? JSONEncoder().encode(SavedFloorPlan(rooms: rooms)) {
            try? data.write(to: jsonURL, options: .atomic)
        }
        return true
    }

    private func style(_ b: UIButton, _ title: String, filled: Bool, action: Selector) {
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        b.titleLabel?.adjustsFontSizeToFitWidth = true
        b.titleLabel?.minimumScaleFactor = 0.75
        b.backgroundColor = filled ? UIColor.systemPurple : UIColor.secondarySystemBackground
        b.setTitleColor(filled ? .white : .systemPurple, for: .normal)
        b.layer.cornerRadius = 12
        b.addTarget(self, action: action, for: .touchUpInside)
    }
}

/// QuickLook preview for the exported USDZ floor plan.
struct USDZQuickLook: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let c = QLPreviewController()
        c.dataSource = context.coordinator
        return c
    }
    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}

// MARK: - 2D top-down floor plan (drawn from the RoomPlan scan)
// Renders the scan as a flat blueprint — walls, doors (with swing arcs), windows,
// room names and furniture — viewed straight down, like an apartment listing.
// Reads the geometry saved next to the USDZ at scan time; a scan that covers more
// than one storey gets a floor picker, because two floors drawn on one page would
// print the upstairs on top of the downstairs.

struct FloorPlan2DView: View {
    let jsonURL: URL
    let address: String

    @State private var plan: SavedFloorPlan?
    @State private var storeys: [SavedFloorPlan.Storey] = []
    @State private var storeyIndex = 0
    @State private var loadFailed = false
    /// A rendered plan waiting for the export sheet (F-A-17).
    @State private var export: PlanExport?
    @State private var exportError: String?

    /// The storey on screen. A one-floor scan has exactly one, and the picker
    /// never appears.
    private var current: SavedFloorPlan.Storey? {
        guard storeys.indices.contains(storeyIndex) else { return storeys.first }
        return storeys[storeyIndex]
    }

    /// The caption the renderer prints beside the area — `nil` for a single-storey
    /// scan, where "this room" / "scanned area" is the honest scope.
    private var storyCaption: String? {
        guard let current, !current.isOnlyStorey else { return nil }
        return current.name
    }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            if let current {
                if current.rooms.allSatisfy({ $0.walls.isEmpty }) {
                    emptyState("No walls were detected in this scan. Try re-scanning the room slowly.")
                } else {
                    VStack(spacing: 0) {
                        if storeys.count > 1 {
                            Picker("Floor", selection: $storeyIndex) {
                                ForEach(Array(storeys.enumerated()), id: \.offset) { idx, s in
                                    Text(s.name).tag(idx)
                                }
                            }
                            .pickerStyle(.segmented)
                            .padding(.horizontal, 14)
                            .padding(.top, 10)
                        }

                        Canvas { ctx, size in
                            FloorPlanRenderer.draw(rooms: current.rooms,
                                                   storyLabel: storyCaption,
                                                   in: &ctx, size: size)
                        }
                        .padding(14)
                        .accessibilityLabel(Text(storeys.count > 1
                                                 ? "\(current.name) plan of \(address)"
                                                 : "Room plan of \(address)"))

                        if let exportError {
                            Text(exportError)
                                .font(.rpCaption).foregroundStyle(Theme.warn)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                        }
                        Button { makeExport(current) } label: {
                            Label(storeys.count > 1 ? "Export this floor as an image" : "Export as image",
                                  systemImage: "square.and.arrow.up")
                                .font(.rpBody.weight(.semibold))
                                .frame(maxWidth: .infinity).padding(.vertical, 13)
                                .modifier(RendpropActionLabelSurface(primary: false))
                        }
                        .padding(.horizontal)
                        .padding(.bottom, 10)
                    }
                }
            } else if loadFailed {
                emptyState("Couldn't open this room plan. Try re-scanning the room.")
            } else {
                ProgressView().tint(Theme.accent)
            }
        }
        .onAppear(perform: load)
        .sheet(item: $export) { item in
            PlanExportSheet(image: item.image, address: address)
        }
    }

    /// Render the plan to a shareable/printable PNG-quality image (F-A-17).
    /// Forced to the LIGHT palette: the renderer erases door/window openings by
    /// over-stroking them in `Theme.bg`, so the exported background has to be
    /// the same token — and a plan that goes on a flyer should be ink-on-paper
    /// whatever the phone's appearance setting is.
    private func makeExport(_ storey: SavedFloorPlan.Storey) {
        exportError = nil
        let side: CGFloat = 1400
        let rooms = storey.rooms
        let caption = storyCaption
        let title: String = {
            let base = address.isEmpty ? "Floor plan" : address
            return storeys.count > 1 ? "\(base) — \(storey.name)" : base
        }()
        let content = ZStack {
            Theme.bg
            VStack(spacing: 12) {
                Canvas { ctx, size in
                    FloorPlanRenderer.draw(rooms: rooms, storyLabel: caption, in: &ctx, size: size)
                }
                Text(title)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text("Phone scan estimates · schematic, not to scale; not a survey. Hull area may include unscanned space and is not verified living area.")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.inkDim)
                Text("Exported: " + Date().formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 20)).foregroundStyle(Theme.inkDim)
            }
            .padding(48)
        }
        .frame(width: side, height: side)
        .environment(\.colorScheme, .light)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2                     // 2800 px square — fine for print and MLS
        guard let image = renderer.uiImage else {
            exportError = "Couldn't build the image. Try re-opening this plan."
            return
        }
        Haptics.success()
        export = PlanExport(image: image)
    }

    private func emptyState(_ msg: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "map").font(.system(size: 40, weight: .light)).foregroundStyle(Theme.inkDim)
            Text(msg).font(.rpBody).foregroundStyle(Theme.inkDim)
                .multilineTextAlignment(.center).padding(.horizontal, 40)
        }
    }

    private func load() {
        guard plan == nil, !loadFailed else { return }
        let url = jsonURL
        DispatchQueue.global(qos: .userInitiated).async {
            let decoded = SavedFloorPlan.load(from: url)
            DispatchQueue.main.async {
                if let decoded, !decoded.rooms.isEmpty {
                    self.plan = decoded
                    self.storeys = decoded.storeys
                    self.storeyIndex = 0
                } else {
                    self.loadFailed = true
                }
            }
        }
    }
}

/// A rendered room-plan image waiting for the export sheet.
private struct PlanExport: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// Save / share a rendered room plan. "Saved to Photos" flips only when the
/// Photos write actually succeeded (same rule as every other save on this
/// screen — F-A-16).
struct PlanExportSheet: View {
    let image: UIImage
    let address: String
    var disclosure: String = "Phone scan estimates. Schematic, not to scale; not a survey. Hull area can include unscanned space and does not certify advertised or appraisal living area."
    var additionalFile: URL? = nil
    var canExport: () -> Bool = { true }
    // Re-evaluate the captured freshness closure when a cloud plan refreshes
    // while this sheet is open; each save also checks it after permission awaits.
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var saved = false
    @State private var isSaving = false
    @State private var saveError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 320)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Theme.border))
                        .accessibilityLabel(Text("Room plan image for \(address)"))

                    Text(disclosure)
                        .font(.rpCaption)
                        .foregroundStyle(Theme.inkDim)
                        .multilineTextAlignment(.center)

                    Button { save() } label: {
                        Label(saved ? "Saved to Photos" : "Save to Photos",
                              systemImage: saved ? "checkmark.circle.fill" : "square.and.arrow.down")
                            .font(.rpBody.weight(.semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                            .modifier(RendpropActionLabelSurface(primary: true))
                    }
                    .disabled(saved || isSaving || !canExport())

                    ShareLink(item: Image(uiImage: image),
                              preview: SharePreview(address.isEmpty ? "Room plan" : "Room plan — \(address)",
                                                    image: Image(uiImage: image))) {
                        Label("Share image", systemImage: "square.and.arrow.up")
                            .font(.rpBody.weight(.semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 13)
                            .modifier(RendpropActionLabelSurface(primary: false))
                    }
                    .disabled(!canExport())

                    if let additionalFile {
                        ShareLink(item: additionalFile) {
                            Label("Share PDF · save to Files", systemImage: "doc.richtext")
                                .font(.rpBody.weight(.semibold))
                                .frame(maxWidth: .infinity).padding(.vertical, 13)
                                .modifier(RendpropActionLabelSurface(primary: false))
                        }.accessibilityIdentifier("measurements.sharePDF").disabled(!canExport())
                    }

                    if !canExport() {
                        Text("This plan changed elsewhere or has a shared-edit conflict. Load the current measurements before exporting.")
                            .font(.rpCaption).foregroundStyle(Theme.warn).multilineTextAlignment(.center)
                            .accessibilityIdentifier("measurements.exportChanged")
                    }
                    if let saveError {
                        Text(saveError)
                            .font(.rpCaption)
                            .foregroundStyle(Theme.warn)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding()
            }
            .background(Theme.bg)
            .navigationTitle("Export room plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }

    private func save() {
        guard canExport() else { saveError = "These measurements, listing or workspace changed. Load the current plan before exporting."; return }
        isSaving = true
        saveError = nil
        let img = image
        Task {
            do {
                try await PhotosLibrarySaver.saveImage(img, while: { canExport() })
                await MainActor.run {
                    isSaving = false
                    guard canExport() else { return }
                    saved = true
                    Haptics.success()
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    saveError = error.localizedDescription
                }
            }
        }
    }
}

/// Pure drawing of a scan as a flat top-down plan. Projects every surface and
/// object onto the floor (X–Z) plane and draws it with SwiftUI Canvas.
///
/// Takes an ARRAY of rooms, not one. A structure scan captures each room into its
/// own `CapturedRoom`, but every room in one scan shares a single ARKit world
/// coordinate space — that is precisely why the capture flow keeps the AR session
/// alive between rooms — so all the rooms on one storey can be unioned and drawn
/// as one plan. A one-room scan is just the array-of-one case.
enum FloorPlanRenderer {
    private struct Seg { var a: SIMD2<Float>; var b: SIMD2<Float> }

    /// A wall/door/window/opening → its 2D floor segment (endpoints).
    private static func seg(_ s: CapturedRoom.Surface) -> Seg {
        let t = s.transform
        let center = SIMD2<Float>(t.columns.3.x, t.columns.3.z)
        var dir = SIMD2<Float>(t.columns.0.x, t.columns.0.z)   // local X = length axis
        let l = simd_length(dir)
        dir = l > 1e-5 ? dir / l : SIMD2<Float>(1, 0)
        let half = s.dimensions.x / 2
        return Seg(a: center - dir * half, b: center + dir * half)
    }

    /// An object → its 4 floor-plane footprint corners.
    private static func corners(_ o: CapturedRoom.Object) -> [SIMD2<Float>] {
        let t = o.transform
        let center = SIMD2<Float>(t.columns.3.x, t.columns.3.z)
        var xa = SIMD2<Float>(t.columns.0.x, t.columns.0.z)
        var za = SIMD2<Float>(t.columns.2.x, t.columns.2.z)
        let lx = simd_length(xa); xa = lx > 1e-5 ? xa / lx : SIMD2<Float>(1, 0)
        let lz = simd_length(za); za = lz > 1e-5 ? za / lz : SIMD2<Float>(0, 1)
        let hw = o.dimensions.x / 2, hd = o.dimensions.z / 2
        return [center + xa*hw + za*hd, center + xa*hw - za*hd,
                center - xa*hw - za*hd, center - xa*hw + za*hd]
    }

    /// Convenience for the single-room callers that predate structure scans.
    static func draw(room: CapturedRoom, in ctx: inout GraphicsContext, size: CGSize) {
        draw(rooms: [room], storyLabel: nil, in: &ctx, size: size)
    }

    static func draw(rooms: [CapturedRoom], storyLabel: String?,
                     in ctx: inout GraphicsContext, size: CGSize) {
        let rawWalls = rooms.flatMap { $0.walls }.map(seg)
        guard !rawWalls.isEmpty else { return }

        // STRAIGHTEN FIRST. RoomPlan hands back ARKit world space, so a plan drawn
        // as-captured sits at whatever compass heading the phone happened to have —
        // it renders as a skewed diamond. Rotating by the dominant wall angle both
        // makes the plan read orthogonal like a real floor plan AND makes the
        // bounding box we measure the true width × depth instead of an inflated
        // diagonal. Do this before anything else touches coordinates.
        let theta = dominantWallAngle(rawWalls)
        let cs = cos(-theta), sn = sin(-theta)
        func rot(_ p: SIMD2<Float>) -> SIMD2<Float> {
            SIMD2<Float>(p.x * cs - p.y * sn, p.x * sn + p.y * cs)
        }
        func rotSeg(_ s: Seg) -> Seg { Seg(a: rot(s.a), b: rot(s.b)) }

        let walls = rawWalls.map(rotSeg)
        let doors = rooms.flatMap { $0.doors }.map(seg).map(rotSeg)
        let windows = rooms.flatMap { $0.windows }.map(seg).map(rotSeg)
        let openings = rooms.flatMap { $0.openings }.map(seg).map(rotSeg)
        let objs = rooms.flatMap { $0.objects }.map { (o: $0, pts: corners($0).map(rot)) }

        // ROOM NAMES — the single biggest thing missing from the plan the 4,000 sq ft
        // field test produced. RoomPlan already classifies each area it recognises
        // (kitchen, bedroom, bathroom, dining, living) and hands it back in
        // `sections`, each with a centre point. We were throwing all of that away
        // and captioning furniture instead, which is backwards: a listing floor plan
        // names ROOMS, and draws furniture as unlabelled outlines. iOS 17+ only —
        // the app still deploys to iOS 16, where the plan simply has no room names.
        var roomNames: [(name: String, at: SIMD2<Float>)] = []
        if #available(iOS 17.0, *) {
            for r in rooms {
                for s in r.sections {
                    guard let n = sectionName(s.label) else { continue }
                    let p = rot(SIMD2<Float>(s.center.x, s.center.z))
                    // RoomPlan can emit two sections of the same kind almost on top
                    // of each other in one large open area; two "Kitchen" captions a
                    // foot apart reads as a bug. Genuinely separate rooms of the same
                    // kind (three bedrooms down a hall) are metres apart and both keep
                    // their name.
                    let dup = roomNames.contains { $0.name == n && simd_length($0.at - p) < 1.2 }
                    if !dup { roomNames.append((n, p)) }
                }
            }
        }

        // Bounds over wall endpoints + object footprints.
        var minX = Float.greatestFiniteMagnitude, minY = Float.greatestFiniteMagnitude
        var maxX = -Float.greatestFiniteMagnitude, maxY = -Float.greatestFiniteMagnitude
        func expand(_ p: SIMD2<Float>) {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        for w in walls { expand(w.a); expand(w.b) }
        for o in objs { for c in o.pts { expand(c) } }

        // Overall extent measured from the WALLS only — furniture can overhang a wall
        // in a noisy scan, and a sofa sticking through drywall must not inflate the
        // dimension we print on a listing.
        var wMinX = Float.greatestFiniteMagnitude, wMinY = Float.greatestFiniteMagnitude
        var wMaxX = -Float.greatestFiniteMagnitude, wMaxY = -Float.greatestFiniteMagnitude
        for w in walls {
            for p in [w.a, w.b] {
                wMinX = min(wMinX, p.x); wMaxX = max(wMaxX, p.x)
                wMinY = min(wMinY, p.y); wMaxY = max(wMaxY, p.y)
            }
        }

        // Asymmetric padding: the left and bottom gutters hold dimension lines, and
        // the bottom gutter grows again when there is a legend to sit under them.
        // The legend row only exists if there is anything recognisable to put in it,
        // and the bottom gutter has to be sized before the plan is laid out — so this
        // is a cheap pre-check. What actually goes IN the legend is only known after
        // the drawing pass below (it lists what could not be captioned in place).
        let hasIdentifiable = objs.contains { $0.o.confidence != .low && !label($0.o.category).isEmpty }
        let padTop: CGFloat = 30, padRight: CGFloat = 22
        let padLeft: CGFloat = 44
        let padBottom: CGFloat = hasIdentifiable ? 60 : 42
        let spanX = max(CGFloat(maxX - minX), 0.001)
        let spanY = max(CGFloat(maxY - minY), 0.001)
        let availW = max(size.width - padLeft - padRight, 1)
        let availH = max(size.height - padTop - padBottom, 1)
        let scale = min(availW / spanX, availH / spanY)
        // A degenerate scan (NaN/inf coordinates) would poison every CGPoint below
        // and trap the Int conversions — draw nothing instead.
        guard scale.isFinite, scale > 0, spanX.isFinite, spanY.isFinite else { return }
        let drawW = spanX * scale, drawH = spanY * scale
        let ox = padLeft + (availW - drawW) / 2
        let oy = padTop + (availH - drawH) / 2
        func P(_ p: SIMD2<Float>) -> CGPoint {
            CGPoint(x: ox + CGFloat(p.x - minX) * scale,
                    y: oy + CGFloat(maxY - p.y) * scale)   // flip vertical → reads upright
        }

        let wallWidth = max(4, 0.10 * scale)   // draw ~10 cm-thick walls

        // Furniture footprints (under the walls). Draw the box for everything the
        // scanner is confident about, and caption an item only when the caption
        // genuinely FITS INSIDE its own box.
        //
        // This replaces a fixed `min(boxW, boxH) > 26` point threshold, which was
        // the bug behind "the floor plan can't tell what things are". That number is
        // in SCREEN POINTS, so whether a label appeared depended on how big the plan
        // was — not on what was scanned. On a 2,504 sq ft scan squeezed into a phone
        // canvas the whole plan renders at roughly 23 points per metre, so a two-foot-
        // deep sofa is 21 points deep and lost its name, while a bed at 37 points kept
        // one. That is exactly the plan the field test produced: two beds and a bath
        // labelled, and thirty anonymous grey rectangles. Measuring the text against
        // the box makes the rule scale-independent, and anything still too small to
        // caption is counted in the legend instead of silently disappearing.
        var uncaptioned: [String: Int] = [:]
        for entry in objs {
            let o = entry.o
            if o.confidence == .low { continue }
            let pts = entry.pts.map(P)
            guard pts.count == 4 else { continue }
            var path = Path()
            path.move(to: pts[0]); path.addLine(to: pts[1])
            path.addLine(to: pts[2]); path.addLine(to: pts[3]); path.closeSubpath()
            // accentSoft = adaptive wash (10% light / 20% dark) — plain
            // accent.opacity(0.10) was near-invisible on the dark background.
            ctx.fill(path, with: .color(Theme.accentSoft))
            ctx.stroke(path, with: .color(Theme.inkDim.opacity(0.7)), lineWidth: 1)

            let name = label(o.category)
            guard !name.isEmpty else { continue }
            // RoomPlan reaches for "Storage" whenever it is unsure, so that one
            // category has to clear a higher bar before it gets to claim space on
            // the plan. It still appears in the legend at medium confidence.
            let captionable = (o.category != .storage) || (o.confidence == .high)

            let boxW = hypot(pts[1].x - pts[0].x, pts[1].y - pts[0].y)
            let boxH = hypot(pts[3].x - pts[0].x, pts[3].y - pts[0].y)
            var placed = false
            if captionable {
                // Try progressively smaller type, the way a draughtsman would, and
                // stop at 6.5 pt — below that it is decoration, not information.
                for pt in [9.0, 8.0, 7.0, 6.5] as [CGFloat] {
                    let resolved = ctx.resolve(Text(name)
                        .font(.system(size: pt, weight: .medium))
                        .foregroundColor(Theme.ink))
                    let ts = resolved.measure(in: CGSize(width: 500, height: 100))
                    guard ts.width + 3 <= boxW, ts.height + 2 <= boxH else { continue }
                    let cx = (pts[0].x + pts[2].x) / 2
                    let cy = (pts[0].y + pts[2].y) / 2
                    ctx.draw(resolved, at: CGPoint(x: cx, y: cy))
                    placed = true
                    break
                }
            }
            if !placed { uncaptioned[name, default: 0] += 1 }
        }

        // Walls (thick dark lines).
        for w in walls {
            var p = Path(); p.move(to: P(w.a)); p.addLine(to: P(w.b))
            ctx.stroke(p, with: .color(Theme.ink),
                       style: StrokeStyle(lineWidth: wallWidth, lineCap: .round))
        }

        // Cut openings/doors/windows out of the walls (over-stroke in bg color).
        for s in openings + doors + windows {
            var p = Path(); p.move(to: P(s.a)); p.addLine(to: P(s.b))
            ctx.stroke(p, with: .color(Theme.bg),
                       style: StrokeStyle(lineWidth: wallWidth + 1.5, lineCap: .butt))
        }

        // Windows: a thin glass line across the gap.
        for s in windows {
            var p = Path(); p.move(to: P(s.a)); p.addLine(to: P(s.b))
            ctx.stroke(p, with: .color(Theme.accent), style: StrokeStyle(lineWidth: 2, lineCap: .butt))
        }

        // Doors: a leaf + a quarter-circle swing arc (classic floor-plan symbol).
        for s in doors {
            drawDoor(a: P(s.a), b: P(s.b), in: &ctx)
        }

        // Room names go on LAST, over the walls and furniture, each on its own small
        // plate of background colour so it stays readable wherever it lands. This is
        // the layer an agent actually reads.
        for rn in roomNames {
            let resolved = ctx.resolve(Text(rn.name.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.ink))
            let ts = resolved.measure(in: CGSize(width: 500, height: 100))
            let at = P(rn.at)
            let plate = CGRect(x: at.x - ts.width / 2 - 4, y: at.y - ts.height / 2 - 2,
                               width: ts.width + 8, height: ts.height + 4)
            guard plate.minX > 2, plate.maxX < size.width - 2,
                  plate.minY > 2, plate.maxY < size.height - 2 else { continue }
            ctx.fill(Path(roundedRect: plate, cornerRadius: 4), with: .color(Theme.bg.opacity(0.82)))
            ctx.draw(resolved, at: at)
        }

        // ---- Dimensions -------------------------------------------------
        // Width along the bottom, depth up the left side, both in feet and inches,
        // plus an approximate floor area. This is what makes a scan read as a floor
        // plan an agent can actually put on a listing.
        guard wMaxX > wMinX, wMaxY > wMinY else { return }
        let topLeft = P(SIMD2<Float>(wMinX, wMaxY))
        let botRight = P(SIMD2<Float>(wMaxX, wMinY))

        if botRight.x - topLeft.x > 40 {
            let y = botRight.y + 24
            dimensionLine(from: CGPoint(x: topLeft.x, y: y),
                          to: CGPoint(x: botRight.x, y: y),
                          text: feetInches(wMaxX - wMinX),
                          vertical: false, in: &ctx)
        }
        if botRight.y - topLeft.y > 40 {
            let x = topLeft.x - 26
            dimensionLine(from: CGPoint(x: x, y: topLeft.y),
                          to: CGPoint(x: x, y: botRight.y),
                          text: feetInches(wMaxY - wMinY),
                          vertical: true, in: &ctx)
        }

        // Area is an estimate, and it says so. A phone scan is not a measured survey,
        // and square footage is a number agents get sued over.
        //
        // Summed PER ROOM, never as one hull over the whole storey. This is still
        // a CONVEX HULL estimate: an L-shaped room bridges its notch, and adjacent
        // scan-room hulls can overlap. Label the algorithm and approximation;
        // this number must never be treated as measured or appraisal living area.
        var areaSqM: Float = 0
        for r in rooms {
            var pts: [SIMD2<Float>] = []
            for w in r.walls.map(seg).map(rotSeg) { pts.append(w.a); pts.append(w.b) }
            areaSqM += footprintArea(pts)
        }
        let areaSqFt = areaSqM * 10.763_91
        if areaSqFt.isFinite, areaSqFt >= 1, areaSqFt < 1_000_000 {
            // A bare "≈ N sq ft" beside a plan reads as the whole property's square
            // footage, which is a number agents get sued over (F-A-17). The caption
            // has to say exactly how much of the building this number covers — and
            // now that a scan can hold several rooms across several storeys, "this
            // room" is no longer true either.
            let scope: String
            if let storyLabel { scope = storyLabel }
            else if rooms.count > 1 || roomNames.count > 1 { scope = "scanned area" }
            else { scope = "this room" }
            ctx.draw(Text("Scan hull estimate ≈ \(Int(areaSqFt.rounded())) sq ft · \(scope)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Theme.inkDim),
                     at: CGPoint(x: padLeft - 8, y: 16), anchor: .leading)
        }

        // The legend: everything the scanner recognised but could not caption in
        // place. Without it, a small item on a large plan is an anonymous grey
        // rectangle and the app looks like it failed to identify anything.
        if let legend = legendLine(uncaptioned) {
            ctx.draw(Text(legend)
                        .font(.system(size: 9.5, weight: .regular))
                        .foregroundColor(Theme.inkDim),
                     at: CGPoint(x: padLeft - 8, y: size.height - 14), anchor: .leading)
        }
    }

    /// "Also identified: 6 chairs · 3 tables · 2 lamps" — a compact inventory of the
    /// confidently-recognised items, so nothing the scan understood is thrown away
    /// just because it was too small to caption on the page.
    private static func legendLine(_ counts: [String: Int]) -> String? {
        guard !counts.isEmpty else { return nil }
        let parts = counts
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(7)
            .map { "\($0.value) \(plural($0.key, $0.value))" }
        return "Also identified: " + parts.joined(separator: " · ")
    }

    /// Lower-cased and pluralised for the legend. A handful of the RoomPlan category
    /// names are already plural or don't take an "s".
    private static func plural(_ name: String, _ n: Int) -> String {
        let lower = name.lowercased()
        guard n != 1 else { return lower }
        switch lower {
        case "stairs", "laundry": return lower
        case "storage":           return "storage units"
        case "tv":                return "TVs"
        default:                  return lower + "s"
        }
    }

    /// Length-weighted dominant wall direction, folded into 0–90° because a room's
    /// walls form a right-angled grid: mapping each angle to 4× puts that 90° period
    /// onto a full circle so the directions can be averaged as vectors (a plain mean
    /// would be wrong across the 0°/90° wrap).
    private static func dominantWallAngle(_ walls: [Seg]) -> Float {
        var sx: Float = 0, sy: Float = 0
        for w in walls {
            let d = w.b - w.a
            let len = simd_length(d)
            guard len > 1e-4 else { continue }
            let a = atan2(d.y, d.x)
            sx += len * cos(4 * a)
            sy += len * sin(4 * a)
        }
        guard sx != 0 || sy != 0 else { return 0 }
        return atan2(sy, sx) / 4
    }

    /// Metres → `14'6"`, rounded to the nearest inch (12" rolls up to the next foot).
    private static func feetInches(_ metres: Float) -> String {
        let inches = Double(metres) * 39.370_078_7
        guard inches.isFinite, inches >= 0, inches < 1_000_000 else { return "—" }   // Int(NaN) traps
        let totalInches = Int(inches.rounded())
        let ft = totalInches / 12, inch = totalInches % 12
        return inch == 0 ? "\(ft)'" : "\(ft)'\(inch)\""
    }

    /// Convex hull (Andrew's monotone chain) of the wall endpoints → shoelace area,
    /// in square metres.
    private static func footprintArea(_ pts: [SIMD2<Float>]) -> Float {
        guard pts.count >= 3 else { return 0 }
        let sorted = pts.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        func cross(_ o: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var hull: [SIMD2<Float>] = []
        for p in sorted {
            while hull.count >= 2, cross(hull[hull.count - 2], hull[hull.count - 1], p) <= 0 {
                hull.removeLast()
            }
            hull.append(p)
        }
        let upperFloor = hull.count + 1
        for p in sorted.reversed() {
            while hull.count >= upperFloor, cross(hull[hull.count - 2], hull[hull.count - 1], p) <= 0 {
                hull.removeLast()
            }
            hull.append(p)
        }
        hull.removeLast()   // last point repeats the first
        guard hull.count >= 3 else { return 0 }
        var acc: Float = 0
        for i in 0..<hull.count {
            let p = hull[i], q = hull[(i + 1) % hull.count]
            acc += p.x * q.y - q.x * p.y
        }
        return abs(acc) / 2
    }

    /// An architectural dimension line: a hairline run, a tick at each end, and the
    /// measurement set off the line so it never sits on top of it.
    private static func dimensionLine(from a: CGPoint, to b: CGPoint, text: String,
                                      vertical: Bool, in ctx: inout GraphicsContext) {
        let stroke = Theme.inkDim.opacity(0.75)
        var run = Path(); run.move(to: a); run.addLine(to: b)
        ctx.stroke(run, with: .color(stroke), lineWidth: 1)

        let t: CGFloat = 4
        var ticks = Path()
        for p in [a, b] {
            if vertical {
                ticks.move(to: CGPoint(x: p.x - t, y: p.y)); ticks.addLine(to: CGPoint(x: p.x + t, y: p.y))
            } else {
                ticks.move(to: CGPoint(x: p.x, y: p.y - t)); ticks.addLine(to: CGPoint(x: p.x, y: p.y + t))
            }
        }
        ctx.stroke(ticks, with: .color(stroke), lineWidth: 1)

        let label = Text(text).font(.system(size: 11, weight: .semibold)).foregroundColor(Theme.ink)
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        if vertical {
            // Run the text up the line, the way a plan reads.
            ctx.drawLayer { layer in
                layer.translateBy(x: mid.x - 11, y: mid.y)
                layer.rotate(by: .degrees(-90))
                layer.draw(label, at: .zero)
            }
        } else {
            ctx.draw(label, at: CGPoint(x: mid.x, y: mid.y - 11))
        }
    }

    private static func drawDoor(a: CGPoint, b: CGPoint, in ctx: inout GraphicsContext) {
        let len = hypot(b.x - a.x, b.y - a.y)
        guard len > 1 else { return }
        let perp = CGPoint(x: -(b.y - a.y) / len, y: (b.x - a.x) / len)
        let leafEnd = CGPoint(x: a.x + perp.x * len, y: a.y + perp.y * len)
        var leaf = Path(); leaf.move(to: a); leaf.addLine(to: leafEnd)
        ctx.stroke(leaf, with: .color(Theme.inkDim), lineWidth: 1.5)
        var arc = Path()
        let start = Double(atan2(b.y - a.y, b.x - a.x))
        let end = Double(atan2(leafEnd.y - a.y, leafEnd.x - a.x))
        arc.addArc(center: a, radius: len,
                   startAngle: .radians(start), endAngle: .radians(end), clockwise: false)
        ctx.stroke(arc, with: .color(Theme.inkDim.opacity(0.55)),
                   style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
    }

    /// RoomPlan's own room-type classification → the caption a floor plan puts on a
    /// room. `nil` for anything Apple hasn't taught it to recognise, so the plan says
    /// nothing rather than guessing.
    @available(iOS 17.0, *)
    private static func sectionName(_ l: CapturedRoom.Section.Label) -> String? {
        switch l {
        case .bathroom:   return "Bathroom"
        case .bedroom:    return "Bedroom"
        case .diningRoom: return "Dining"
        case .kitchen:    return "Kitchen"
        case .livingRoom: return "Living room"
        default:          return nil          // .unidentified, and anything added later
        }
    }

    private static func label(_ c: CapturedRoom.Object.Category) -> String {
        switch c {
        case .bed: return "Bed"
        case .sofa: return "Sofa"
        case .table: return "Table"
        case .chair: return "Chair"
        case .storage: return "Storage"
        case .refrigerator: return "Fridge"
        case .stove: return "Stove"
        case .oven: return "Oven"
        case .sink: return "Sink"
        case .toilet: return "Toilet"
        case .bathtub: return "Bath"
        case .washerDryer: return "Laundry"
        case .dishwasher: return "Dishwasher"
        case .television: return "TV"
        case .fireplace: return "Fireplace"
        case .stairs: return "Stairs"
        @unknown default: return ""
        }
    }
}


private struct PropertyVideoProcessorPermissionCard: View {
    @ObservedObject var consent: PropertyVideoProcessorConsent
    var body: some View {
        ZStack {
            Theme.bg.opacity(0.97).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(PropertyVideoProcessorContract.title).font(.rpTitle).foregroundStyle(Theme.ink)
                    Text(PropertyVideoProcessorContract.body).font(.rpBody).foregroundStyle(Theme.inkDim)
                    HStack {
                        Link(destination: URL(string: "https://rendprop.com/privacy")!) {
                            Text("Privacy").frame(minHeight: 44).contentShape(Rectangle())
                        }
                        Spacer()
                        Link(destination: URL(string: "https://kie.ai/terms-of-use")!) {
                            Text("Kie terms").frame(minHeight: 44).contentShape(Rectangle())
                        }
                    }.font(.rpCaption)
                    PrimaryButton(title: PropertyVideoProcessorContract.allowLabel, systemImage: "checkmark") { consent.allow() }
                        .accessibilityIdentifier("video.processor.allow")
                    SecondaryButton(title: PropertyVideoProcessorContract.declineLabel, systemImage: "xmark") { consent.decline() }
                        .accessibilityIdentifier("video.processor.decline")
                }.padding(24).frame(maxWidth: 440)
            }
        }.accessibilityIdentifier("video.processor.disclosure")
    }
}
