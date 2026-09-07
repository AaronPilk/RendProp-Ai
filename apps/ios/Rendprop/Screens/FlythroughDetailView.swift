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

struct FlythroughDetailView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var auth = AuthStore.shared
    @Environment(\.dismiss) private var dismiss
    // LOAD-BEARING: the business type drives every noun, the Zillow/sold gating
    // and which listings exist at all. Switching type while this screen is
    // pushed used to leave a HOUSE open inside Gym mode, still showing
    // "Mark as sold" and the Zillow field (found in the simulator sweep).
    // Observing it both re-renders the copy and pops the screen when this
    // listing no longer belongs to the selected industry.
    @AppStorage("space.type") private var spaceTypeRaw = SpaceType.realEstate.rawValue
    let listing: Listing

    @State private var zillowText = ""
    @State private var zillowSeeded = false
    @State private var zillowError: String?
    @State private var showRoomTagger = false
    @State private var tagsBeforeEdit: [RoomTag] = []
    @State private var chapterSyncNote: String?
    @State private var playerRefresh = UUID()
    @State private var showAerialIntro = false
    @State private var showEdit = false
    @State private var showDeleteConfirm = false
    @State private var isDeleting = false
    /// Which of the two links a QR sheet is being shown for (nil = none).
    @State private var qrTarget: QRTarget?
    @State private var showSignIn = false
    @State private var isPublishing = false
    @State private var publishFailure: AIFailure?

    // MARK: Compliance (W2-C2) — the org's AI provenance rows for THIS listing
    @State private var provenance: [ProvenanceRecord] = []
    @State private var isLoadingProvenance = false
    @State private var provenanceError: String?
    @State private var isExportingAudit = false
    @State private var auditExport: AuditExport?
    @State private var complianceNote: String?
    @State private var isSavingOriginals = false

    // MARK: Files (the 4,000 sq ft field test)
    /// Every file this listing has produced, read off disk on appear. NOT computed
    /// inside `body`: a directory scan per re-render is exactly what
    /// `PhotoStudioView.loadExisting()` avoids by loading into state once.
    @State private var mediaItems: [ListingMediaItem] = []
    /// The file being viewed. ONE binding for every kind — `ListingFileViewer`
    /// switches internally — so `body` grows a single presentation modifier.
    @State private var openedFile: ListingMediaItem?
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

    /// The business type this screen speaks in. Samples carry no spaceTypeRaw
    /// (they are reseeded per type), so they follow the current selection.
    private var space: SpaceType {
        currentListing.isSample ? SpaceType.current : currentListing.spaceType
    }

    /// Two-way binding into the model's asset so the room tagger edits persist
    /// and the player refreshes.
    private var roomTagsBinding: Binding<[RoomTag]> {
        Binding(
            get: { model.assets[listing.id]?.roomTags ?? [] },
            set: { newTags in
                if var a = model.assets[listing.id] {
                    a.roomTags = newTags
                    model.assets[listing.id] = a
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

    /// Toolbox mini feature card — the feature's signature gradient (same one
    /// it wears on Home), white icon, name, and a short promise.
    private func toolCard(_ title: String, _ sub: String, _ icon: String,
                          _ gradient: LinearGradient, ai: Bool = false,
                          dimmed: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.white)
                Spacer()
                if ai { AIPill() }
            }
            Spacer(minLength: 8)
            Text(title)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Color.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(sub)
                .font(.caption2)
                .foregroundStyle(Color.white.opacity(0.88))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.top, 1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 96)
        .background(gradient)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .opacity(dimmed ? 0.45 : 1)
    }

    private var asset: CaptureAsset? { model.assets[listing.id] }
    private var tour: AppModel.RenderedTour? { model.tours[listing.id] }

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

    private var needsSignIn: Bool { Config.enableAuth && !auth.isSignedIn }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                tourSection
                if let shareURL {
                    shareSection(shareURL)
                } else {
                    nextStepCard
                }
                complianceSection
                toolboxSection
                filesSection
                if !currentListing.isSample {
                    manageSection
                }
                performanceSection
                infoSection
                detailsSection
                mapSection
            }
            .padding()
        }
        .background(Theme.bg)
        .navigationTitle(currentListing.address)
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isDeleting)
        .onAppear {
            // Seed the Zillow field ONCE — re-seeding on every appearance wiped
            // an in-progress paste when a sheet closed (F-A-26).
            if !zillowSeeded {
                zillowText = currentListing.zillowURL ?? ""
                zillowSeeded = true
            }
            geocodeIfNeeded()
            // Still called on every appearance — coming back from AI Photo
            // Studio, Reel Studio or the floor-plan scanner is a push/pop, so
            // this is where a file made in one of them first becomes visible
            // here. It is no longer a directory sweep on the main thread: see
            // `loadFiles`, which checks five modification dates on a background
            // thread and does nothing at all when none of them moved.
            loadFiles()
        }
        .fullScreenCover(item: $openedFile) { item in
            ListingFileViewer(item: item)
        }
        .task { await loadCompliance() }
        .onChange(of: spaceTypeRaw) { _ in
            // The list this screen was opened from no longer contains this
            // listing — go back rather than showing another industry's detail.
            if !currentListing.belongsToCurrentType { dismiss() }
        }
        .sheet(isPresented: $showRoomTagger, onDismiss: roomTaggerDismissed) {
            if let a = asset {
                RoomTaggerView(videoURL: a.localURL, tags: roomTagsBinding,
                               suggest: roomTagSuggestSource)
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
        .sheet(item: $qrTarget) { target in
            QRShareSheet(url: target.url, title: currentListing.address,
                         linkName: target.linkName, caption: target.caption)
        }
        .sheet(item: $auditExport) { export in
            ShareSheet(items: [export.url])
        }
        .sheet(isPresented: $showSignIn) {
            SignInView(onSignedIn: { publishNow() })
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

    private var tourSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(playbackURL != nil ? "YOUR TOUR" : "SAMPLE TOUR")
                .font(.rpKicker).foregroundStyle(Theme.inkDim)
            Group {
                if currentListing.isSample, space != .realEstate, !PlayerWebView.bundledDemoAvailable,
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
                .frame(height: 460)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                        .strokeBorder(Theme.border)
                )
            Text(tourCaption)
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
                url: url,
                icon: "person.text.rectangle.fill",
                tint: Theme.accent,
                name: "Your link",
                blurb: "\(space.profileCardName) + lead capture. Email, social, texts, QR.",
                shareSubject: currentListing.address,
                shareMessage: "Fly through \(currentListing.address) — scroll to walk the \(space.spaceNoun).",
                shareTitle: "Share your link",
                qrCaption: space == .realEstate
                    ? "Scan to open your branded tour — flyers, sign riders, open-house sheets."
                    : "Scan to open your branded tour — flyers, counter cards, the front window.")

            if let mls = currentListing.serverUnbrandedURL {
                linkCard(
                    url: mls,
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
        }
    }

    /// One labelled link: what it is, the URL itself, Copy / QR, and Share.
    /// `warning` renders the MLS one-liner under the row.
    private func linkCard(url: URL, icon: String, tint: Color, name: String, blurb: String,
                          shareSubject: String, shareMessage: String, shareTitle: String,
                          qrCaption: String, warning: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 10) {
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

            Text(url.absoluteString)
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
                    UIPasteboard.general.url = url
                    Haptics.success()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                .accessibilityLabel(Text("Copy \(name)"))
                Button {
                    qrTarget = QRTarget(url: url, linkName: name, caption: qrCaption)
                } label: {
                    Label("QR", systemImage: "qrcode")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                .accessibilityLabel(Text("QR code for \(name)"))
            }
            .font(.rpBody)

            ShareLink(item: url, subject: Text(shareSubject), message: Text(shareMessage)) {
                Label(shareTitle, systemImage: "square.and.arrow.up")
                    .font(.rpBody.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(tint)
                    .foregroundStyle(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
    }

    /// The honest next step for a listing that has no share link yet — a real
    /// action, never a passive "publish to get your link" banner (F-A-08):
    /// rendered tour → Publish; video but no tour → Create tour; nothing → Add
    /// a walkthrough; sample → create your own.
    @ViewBuilder private var nextStepCard: some View {
        if currentListing.isSample {
            sampleCard
        } else if tour != nil {
            publishCard
        } else if let a = asset {
            createTourCard(a)
        } else {
            addVideoCard
        }
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
            .background(Theme.accent)
            .foregroundStyle(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                              onSignIn: { showSignIn = true })
            }
            if isPublishing {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Publishing — uploading the rendered video. Keep the app open.")
                        .font(.rpCaption).foregroundStyle(Theme.inkDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            } else {
                Button { publishNow() } label: {
                    nextStepLabel(hasPublishProblem ? "Retry publish" : "Publish tour", "icloud.and.arrow.up")
                }
                .buttonStyle(ScalePressStyle())
                if needsSignIn {
                    Text("Publishing needs a free account — you'll be asked to sign in with Apple.")
                        .font(.rpCaption).foregroundStyle(Theme.inkDim)
                }
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
                           "Record a walkthrough or upload a clip. The tour, share link and leads all start from that video.")
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

    /// Toolbox — every feature for this listing, one tap away. Every tool that
    /// writes files or calls AI is disabled on samples (decision A7): a sample's
    /// output would be orphaned, and the AI would run against a demo.
    private var toolboxSection: some View {
        let sample = currentListing.isSample
        let createFirst = "Create a \(space.spaceNoun) first"
        // Read off the FILES scan, not off `currentListing.aerialURL`: that
        // property does a `fileExists` every time it is touched, and this line
        // sits in a computed property `body` reads, so it was a stat syscall on
        // EVERY re-render of this screen — a save, a note, a scroll-driven state
        // change (the build-9 lag report). The scan already did that check, off
        // the main thread, and it is the same answer: it only lists an aerial
        // whose file is really there.
        let aerialSub = mediaItems.contains { $0.kind == .aerial } ? "Aerial ready" : "AI opening shot"
        return VStack(alignment: .leading, spacing: 10) {
            Text("TOOLBOX").font(.rpKicker).foregroundStyle(Theme.inkDim)
                .frame(maxWidth: .infinity, alignment: .leading)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                GridItem(.flexible(), spacing: 10)], spacing: 10) {
                NavigationLink { PhotoStudioView(listing: currentListing) } label: {
                    toolCard("AI Photo Studio", sample ? createFirst : "Sky · tidy · furniture",
                             "wand.and.stars", RPGradient.photo, ai: true, dimmed: sample)
                }
                .buttonStyle(ScalePressStyle())
                .disabled(sample)
                .accessibilityIdentifier("detail.photoStudio")

                NavigationLink { PhotoStudioView(listing: currentListing, intent: .reel) } label: {
                    toolCard("Make a reel", sample ? createFirst : "Video + your voice",
                             "film.stack", RPGradient.reel, ai: true, dimmed: sample)
                }
                .buttonStyle(ScalePressStyle())
                .disabled(sample)
                .accessibilityIdentifier("detail.reelStudio")

                Button {
                    tagsBeforeEdit = asset?.roomTags ?? []
                    showRoomTagger = true
                } label: {
                    toolCard(space == .realEstate ? "Tag rooms" : "Tag areas",
                             sample ? createFirst : (asset == nil ? "Needs your own video" : "Tap-to-jump chapters"),
                             "mappin.and.ellipse", RPGradient.rooms, dimmed: asset == nil || sample)
                }
                .buttonStyle(ScalePressStyle())
                .disabled(asset == nil || sample)

                NavigationLink { FloorPlanView(listing: currentListing) } label: {
                    toolCard("Floor plan", sample ? createFirst : "Scan in 3D or upload",
                             "cube.transparent", RPGradient.plan, dimmed: sample)
                }
                .buttonStyle(ScalePressStyle())
                .disabled(sample)

                Button { showAerialIntro = true } label: {
                    toolCard("Aerial intro", sample ? createFirst : aerialSub,
                             "airplane.departure", RPGradient.aerial, ai: true, dimmed: sample)
                }
                .buttonStyle(ScalePressStyle())
                .disabled(sample)

                NavigationLink { AgentCardEditorView() } label: {
                    toolCard(space.profileCardName, "On every link you share",
                             "person.text.rectangle.fill", RPGradient.agent)
                }
                .buttonStyle(ScalePressStyle())
            }
        }
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
                    ForEach(fileRows) { item in fileRow(item) }
                    filePhotoGrid
                }
                if let filesNote { filesNoteRow(filesNote) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
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
            Text("Everything you make with the tools above — reels, photos, a flyover, a floor plan — is saved here automatically and stays on this phone. You can put any of it in your Photos app with one tap.")
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
            }
        }
        .buttonStyle(ScalePressStyle())
        // OUTSIDE the button's label, not inside it: an overlay applied here is a
        // sibling above the button and gets its own taps. Inside the label it
        // would be swallowed by the row's own gesture.
        .overlay(alignment: .topTrailing) { photoSaveBadge(item) }
        .accessibilityLabel(Text("Photo. \(item.dateLabel). Opens before and after."))
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
        ShareLink(item: item.url) {
            Label("Share", systemImage: "square.and.arrow.up")
        }
    }

    private func openFile(_ item: ListingMediaItem) {
        Haptics.selection()
        openedFile = item
    }

    /// Copy one file into the user's Photos library. Videos and photo FILES take
    /// different `PhotosLibrarySaver` calls — `saveImageFile` writes the exact
    /// bytes rather than re-encoding, which matters when the "photo" is a
    /// compliance original a broker may ask for (W2-C2).
    private func saveFileToPhotos(_ item: ListingMediaItem) {
        guard !isSavingFile else { return }
        isSavingFile = true
        filesNote = nil
        let url = item.url
        let isVideo = item.isVideo
        let what = item.title
        let id = item.id
        let kind = item.kind.rawValue
        Task {
            do {
                if isVideo {
                    try await PhotosLibrarySaver.saveVideo(at: url)
                } else {
                    try await PhotosLibrarySaver.saveImageFile(at: url)
                }
                await MainActor.run {
                    isSavingFile = false
                    savedFiles.insert(id)
                    filesNoteOK = true
                    filesNote = "\(what) is now in your Photos app."
                    Haptics.success()
                    Analytics.track("file_saved", ["kind": kind, "ok": "true"])
                }
            } catch {
                await MainActor.run {
                    isSavingFile = false
                    filesNoteOK = false
                    filesNote = error.localizedDescription
                    Analytics.track("file_saved", ["kind": kind, "ok": "false"])
                }
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
            guard let scan = await ListingMediaItem.scan(request, since: since) else { return }
            guard !Task.isCancelled else { return }
            filesStamp = scan.stamp
            // Only publish a list that is actually different. An equal array
            // still invalidates `@State` and re-runs `body`, which on this screen
            // means re-laying out every file row for no reason.
            if scan.items != mediaItems { mediaItems = scan.items }
        }
    }

    // MARK: - Compliance (W2-C2)

    /// Every AI-altered or AI-generated asset on this listing, with the exact
    /// disclosure sentence the public tour prints, a link to the unaltered
    /// original, and the two things a broker actually asks for: the originals on
    /// file and the audit log as a CSV.
    ///
    /// Hidden until there is something to disclose. A listing with no
    /// provenance rows gets NO reassuring "nothing was altered" line — rows
    /// only exist from the compliance wave forward, so that claim could be
    /// false for media generated by an earlier build.
    @ViewBuilder private var complianceSection: some View {
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
                            .background(Theme.accentSoft).foregroundStyle(Theme.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .disabled(isSavingOriginals || !provenance.contains(where: { $0.hasOriginal }))

                    Button { exportAudit() } label: {
                        Label(isExportingAudit ? "Building the audit…"
                                : (space == .realEstate ? "Email my broker the audit" : "Export the audit log"),
                              systemImage: "doc.text")
                            .font(.rpBody.weight(.semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(Theme.accentSoft).foregroundStyle(Theme.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                model.setSold(!currentListing.isSold, for: listing.id)
                playerRefresh = UUID()
                Haptics.success()
            } label: {
                Label(currentListing.isSold ? "Mark as active" : "Mark as \(space.archiveVerb)",
                      systemImage: currentListing.isSold ? "arrow.uturn.backward" : "checkmark.seal.fill")
                    .font(.rpBody.weight(.semibold))
                    .foregroundStyle(currentListing.isSold ? Theme.inkDim : Theme.accent)
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
        var text = currentListing.serverShareURL != nil
            ? "Removes the video, photos and tour from this phone and takes both share links offline. This can't be undone."
            : "Removes the video, photos and tour from this phone. This can't be undone."
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

    /// Publish the EXISTING local render (no re-render) — decision A2. Sign-in
    /// gate first; progress + the server's real error inline.
    private func publishNow() {
        guard !isPublishing, tour != nil, !currentListing.isSample else { return }
        if needsSignIn { showSignIn = true; return }
        isPublishing = true
        publishFailure = nil
        Haptics.selection()
        let id = listing.id
        Task {
            do {
                _ = try await model.publishExisting(listingID: id)
                await MainActor.run {
                    isPublishing = false
                    playerRefresh = UUID()
                    Haptics.success()
                    ReviewPrompter.shared.tourPublished()
                }
            } catch {
                await MainActor.run {
                    isPublishing = false
                    publishFailure = AIFailure(error, title: "Couldn't publish")
                }
            }
        }
    }

    /// Load this listing's provenance rows (GET /me/compliance?listing_id=).
    /// Silent when the account has no access or the route is missing — the card
    /// stays hidden rather than shouting at an agent who did nothing wrong.
    private func loadCompliance() async {
        let l = currentListing
        guard !l.isSample, let serverID = l.serverID else { return }
        guard !Config.enableAuth || auth.isSignedIn else { return }
        guard !isLoadingProvenance else { return }
        isLoadingProvenance = true
        provenanceError = nil
        defer { isLoadingProvenance = false }
        do {
            provenance = try await model.api.provenance(listingServerID: serverID)
        } catch is CancellationError {
            // The screen was left mid-load (a push cancels `.task`) — say nothing;
            // coming back re-runs it.
        } catch {
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
    private func saveOriginalsToPhotos() {
        guard !isSavingOriginals else { return }
        let urls = provenance.compactMap { $0.originalURL }
        guard !urls.isEmpty else { return }
        isSavingOriginals = true
        complianceNote = nil
        Haptics.selection()
        Task {
            var saved = 0
            var failure: String?
            for remote in urls {
                var staged: URL?
                do {
                    let (tmp, response) = try await URLSession.shared.download(from: remote)
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
                    try await PhotosLibrarySaver.saveImageFile(at: dest)
                    saved += 1
                } catch {
                    if failure == nil { failure = AIFailure(error).message }
                }
                if let staged { try? FileManager.default.removeItem(at: staged) }
            }
            let total = urls.count
            let done = saved
            let why = failure
            await MainActor.run {
                isSavingOriginals = false
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
    }

    /// Fetch the broker-exportable CSV for this listing and hand it to the share
    /// sheet, so "email my broker the audit" is one tap and a real attachment.
    private func exportAudit() {
        guard !isExportingAudit, let serverID = currentListing.serverID else { return }
        isExportingAudit = true
        complianceNote = nil
        Haptics.selection()
        let api = model.api               // snapshot on the main actor
        let address = currentListing.address
        Task {
            do {
                let csv = try await api.complianceCSV(listingServerID: serverID)
                let name = Self.auditFilename(for: address)
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent(name)
                try? FileManager.default.removeItem(at: dest)
                try csv.write(to: dest, options: .atomic)
                await MainActor.run {
                    isExportingAudit = false
                    auditExport = AuditExport(url: dest)
                    Haptics.success()
                }
            } catch {
                await MainActor.run {
                    isExportingAudit = false
                    complianceNote = "Couldn't build the audit export — \(AIFailure(error).message)"
                }
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
        playerRefresh = UUID()
        let l = currentListing
        guard !l.isSample, let renderID = l.publishedRenderID, tour != nil else { return }
        let tags = (model.assets[listing.id]?.roomTags ?? []).filter { !$0.isFromAI }
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
        Task {
            do {
                try await api.updateChapters(renderID: renderID, chapters: chapters)
                await MainActor.run { chapterSyncNote = "Chapters updated on your share link." }
            } catch {
                let why = AIFailure(error).message
                await MainActor.run {
                    chapterSyncNote = "Couldn't update the chapters on your share link — \(why)"
                }
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
/// right next step — "Upgrade plan" on 402, "Sign in" on 401, "try again in a
/// few minutes" on 429.
private struct AIFailure: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let isQuota: Bool
    let isUnauthorized: Bool
    let isRateLimited: Bool

    // No `pricingURL` here any more. A 402 on this screen offers the in-app
    // paywall and nothing else — see `Config.pricingURL` (retired, always nil).

    init(_ error: Error, title: String = "That one didn't work") {
        self.title = title
        if let api = error as? APIError {
            var text = ""
            if case .server(_, _, let m) = api { text = m.trimmingCharacters(in: .whitespacesAndNewlines) }
            if text.isEmpty { text = (api.errorDescription ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
            if text.isEmpty { text = "Something went wrong. Please try again." }
            message = text
            isQuota = api.isQuota
            isUnauthorized = api.isUnauthorized
            isRateLimited = api.isRateLimited
        } else if AIFailure.isOffline(error) {
            message = "You're offline — check your connection and try again."
            isQuota = false
            isUnauthorized = false
            isRateLimited = false
        } else {
            let text = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            message = text.isEmpty ? "Something went wrong. Please try again." : text
            isQuota = false
            isUnauthorized = false
            isRateLimited = false
        }
    }

    init(message: String, title: String = "That one didn't work") {
        self.title = title
        self.message = message
        isQuota = false
        isUnauthorized = false
        isRateLimited = false
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

    /// One-line next step for the status class (empty when there is none).
    var actionHint: String {
        if isQuota { return "This month's allowance for this feature is used up." }
        if isUnauthorized { return "Your session expired — sign in to continue." }
        if isRateLimited { return "Try again in a few minutes." }
        return ""
    }

    /// Message + hint, for alerts that can't lay out a card.
    var fullMessage: String {
        actionHint.isEmpty ? message : "\(message)\n\n\(actionHint)"
    }
}

/// Loud, unmissable failure card with the right next step: the server's message,
/// Upgrade plan on 402 (opens the pricing page — no prices in-app), Sign in on
/// 401, wait on 429, otherwise the caller's retry hint.
private struct AIFailureCard: View {
    let failure: AIFailure
    var retryHint: String = "Adjust the settings and try again."
    /// Which monthly allowance ran out, for the paywall's one context line.
    /// A `plan_entitlements` key — renders | photo_edits | reels | aerials |
    /// drone. Empty = the generic "monthly allowance" wording.
    var quotaFeature: String = ""
    var onSignIn: () -> Void = {}

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
                        .background(Theme.accent).foregroundStyle(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            } else if failure.isUnauthorized {
                Text(failure.actionHint)
                    .font(.rpCaption)
                    .foregroundStyle(Theme.inkDim)
                Button { onSignIn() } label: {
                    Label("Sign in", systemImage: "person.crop.circle")
                        .font(.rpBody.weight(.semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(Theme.accentSoft).foregroundStyle(Theme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            } else if failure.isRateLimited {
                Text(failure.actionHint)
                    .font(.rpCaption)
                    .foregroundStyle(Theme.inkDim)
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
private enum AIImagePrep {
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

    /// The photo at `url` → downscaled JPEG → base64 (no data: prefix), off main.
    static func jpegBase64(at url: URL, maxDimension: CGFloat, quality: CGFloat) async -> String? {
        await Task.detached(priority: .userInitiated) { () -> String? in
            guard let ui = UIImage(contentsOfFile: url.path) else { return nil }
            return AIImagePrep.downscaled(ui, maxDimension: maxDimension)
                .jpegData(compressionQuality: quality)?
                .base64EncodedString()
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

/// Photos-library saves with a REAL completion (F-A-16). Both calls throw on a
/// denied permission or a failed write, so a caller flips "Saved to Photos"
/// only when the asset actually landed.
private enum PhotosLibrarySaver {
    struct Denied: LocalizedError {
        var errorDescription: String? {
            "Rendprop isn't allowed to add to your Photos. Allow it in Settings → Rendprop → Photos, then try again."
        }
    }

    static func saveVideo(at url: URL) async throws {
        try await ensureAddAccess()
        try await PHPhotoLibrary.shared().performChanges {
            _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }

    static func saveImage(_ image: UIImage) async throws {
        try await ensureAddAccess()
        try await PHPhotoLibrary.shared().performChanges {
            _ = PHAssetChangeRequest.creationRequestForAsset(from: image)
        }
    }

    /// Save an image FILE as-is — no decode, no re-encode. Used for compliance
    /// originals (W2-C2): a re-encoded "original" is not the original, and a
    /// broker who asks for the unaltered image is entitled to the exact bytes
    /// the public "View original" link serves.
    static func saveImageFile(at url: URL) async throws {
        try await ensureAddAccess()
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
                                .background(Theme.accent).foregroundStyle(Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .disabled(saved || isSaving)

                        ShareLink(item: Image(uiImage: image),
                                  preview: SharePreview("\(linkName) QR — \(title)", image: Image(uiImage: image))) {
                            Label("Share QR code", systemImage: "square.and.arrow.up")
                                .font(.rpBody.weight(.semibold))
                                .frame(maxWidth: .infinity).padding(.vertical, 13)
                                .background(Theme.accentSoft).foregroundStyle(Theme.accent)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
    /// "Your reel" answers it in two words where "Reel" does not.
    var title: String {
        switch kind {
        case .tour:       return "Your walkthrough tour"
        case .reel:       return "Your reel"
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
        case .reel:       return "Post it to Instagram, TikTok or YouTube"
        case .aerial:     return "The flyover that opens your reel"
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
                                          createdAt: entry.createdAt))
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
                            .background(saved ? Theme.good : Theme.accent)
                            .foregroundStyle(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                            .background(Theme.accentSoft).foregroundStyle(Theme.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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

/// One full-screen cover for every kind of file, so the listing screen grows a
/// single presentation modifier rather than three (this file has hit the
/// type-checker's expression budget before, and `body` is already long).
/// Each branch is a viewer that already exists and already works.
private struct ListingFileViewer: View {
    let item: ListingMediaItem

    var body: some View {
        switch item.kind {
        case .photo:
            // The photo studio's own before/after view, unchanged. A photo with no
            // separate "before" on disk is its own before, exactly as
            // `EnhancedPhoto.loadAll` records it.
            PhotoCompareView(photo: EnhancedPhoto(id: item.id,
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
            ListingFilePreview(item: item)
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
}

extension EnhancedPhoto {
    /// Per-listing photo directory (Documents/Photos/<listingID>/). Not created here.
    static func directory(for listingID: UUID) -> URL {
        FileStore.documents.appendingPathComponent("Photos/\(listingID.uuidString)", isDirectory: true)
    }

    /// Every enhanced photo on disk for a listing, newest first. Sorted by real
    /// file creation date (mixing UUID and timestamp ids reordered AI edits vs
    /// ingests unpredictably across relaunches); `orig-<id>.jpg` beside an
    /// `enh-<id>.jpg` is the "before", else the photo is its own before.
    ///
    /// SIGNATURE UNCHANGED, deliberately. `PhotoStudioView.loadExisting`, the
    /// Reel Studio hand-off and `CoachModel.photoCounts` all call this
    /// synchronously and none of them wanted an `await`; the build-9 lag report
    /// only asked that it stop costing what it cost, so the body moved onto
    /// `dated(in:directory:)` and the callers are untouched.
    nonisolated static func loadAll(listingID: UUID) -> [EnhancedPhoto] {
        let dir = directory(for: listingID)
        return dated(in: DiskScan.entries(of: dir), directory: dir).map(\.photo)
    }

    /// The scan behind `loadAll`, over a directory listing the caller already
    /// has, keeping each photo's creation date instead of throwing it away.
    ///
    /// TWO syscall bills paid off here, both mine (the build-9 lag report):
    ///
    /// 1. The sort used to call `created()` inside the comparator, so a folder of
    ///    n photos was stat'd O(n log n) times to answer a question with n
    ///    answers. The date now comes off the enumeration once, in `DatedFile`.
    /// 2. Finding the "before" used to be a `fileExists` PER PHOTO — twenty
    ///    photos, twenty syscalls — for a fact the directory listing in front of
    ///    us already contains. It is a set lookup now.
    ///
    /// The result is byte-for-byte the list build 8 produced, including the
    /// `a.id > b.id` tie-break, which matters on the rare pair of files written
    /// inside the same filesystem timestamp.
    nonisolated fileprivate static func dated(in entries: [DatedFile],
                                              directory dir: URL) -> [DatedPhoto] {
        let names = Set(entries.map(\.name))
        return entries
            .filter { $0.name.hasPrefix("enh-") }
            .map { file -> DatedPhoto in
                let id = file.url.deletingPathExtension().lastPathComponent
                    .replacingOccurrences(of: "enh-", with: "")
                let origName = "orig-\(id).jpg"
                let origURL = names.contains(origName) ? dir.appendingPathComponent(origName) : file.url
                return DatedPhoto(photo: EnhancedPhoto(id: id, originalURL: origURL,
                                                       enhancedURL: file.url),
                                  createdAt: file.createdAt)
            }
            .sorted { a, b in
                a.createdAt != b.createdAt ? a.createdAt > b.createdAt : a.photo.id > b.photo.id
            }
    }
}

struct PhotoStudioView: View {
    /// Why the studio was opened — `.reel` rings the "Make a reel" card so the
    /// deep link lands on the thing the agent tapped for.
    enum Intent { case photos, reel }

    /// One place for the words on every edit button, so the empty-state chip,
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
    let listing: Listing
    var intent: Intent = .photos

    private var mainRelPath: String? {
        model.listings.first(where: { $0.id == listing.id })?.mainPhotoRelPath
    }
    private func isMain(_ p: EnhancedPhoto) -> Bool {
        mainRelPath == FileStore.relativePath(for: p.enhancedURL)
    }

    /// This listing's finished aerial clip, if it has one — read LIVE from the
    /// model, because `listing` is a value snapshot taken when this screen was
    /// pushed and the aerial may have been generated since. `Listing.aerialURL`
    /// already returns nil when the file is gone.
    private var aerialClipURLs: [URL] {
        let live = model.listings.first(where: { $0.id == listing.id }) ?? listing
        return live.aerialURL.map { [$0] } ?? []
    }
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
        model.setMainPhoto(FileStore.relativePath(for: p.enhancedURL), for: listing.id)
        Haptics.success()
    }

    /// The business type the copy speaks in (samples follow the current type).
    private var space: SpaceType { listing.isSample ? SpaceType.current : listing.spaceType }
    /// The INDUSTRY term, used only where it must be exact: the staging
    /// dialog's explanation and the disclosure copy. Buttons say "Add furniture"
    /// (see `EditWords`) — plain words on the button, honest words in the note.
    private var stagingLabel: String { space == .realEstate ? "Virtual staging" : "Furnish & style" }

    @State private var photos: [EnhancedPhoto] = []
    @State private var showLibrary = false
    @State private var showCamera = false
    @State private var isProcessing = false
    @State private var processingText = "Working on your photo…"
    @State private var compare: EnhancedPhoto?
    @State private var aiFailure: AIFailure?
    @State private var animatedClip: AnimatedClip?   // finished photo→reel clip
    @State private var customEditPhoto: EnhancedPhoto?   // photo awaiting a custom-prompt AI edit
    @State private var showReelStudio = false            // multi-photo → stitched social reel
    @State private var animateTask: Task<Void, Never>?   // photo→clip poll; cancelled when the studio is left
    @State private var wandPhoto: EnhancedPhoto?         // photo under the visible wand button
    @State private var showWandDialog = false            // wand → change-this-photo chooser
    @State private var stagePhoto: EnhancedPhoto?        // photo awaiting a staging style
    @State private var showStageDialog = false           // staging style chooser
    @State private var suggestResult: SuggestResult?     // AI-suggested edits sheet payload
    @State private var showSignIn = false                // AI edits run on the user's account
    /// The edit an EMPTY-STATE CHIP asked for while there were no photos yet. The
    /// chips used to be decoration; now one picks a photo and this remembers what
    /// to do with it the moment the import lands. Cleared on a cancelled picker.
    @State private var pendingShowcaseEdit: String?
    /// The disclosure sentence the server recorded for each AI edit made this
    /// session, keyed by photo id — shown verbatim in the before/after view
    /// (W2-C4). Not persisted: the durable copy is the provenance row, which the
    /// listing's COMPLIANCE card reads back from the server.
    @State private var editDisclosures: [String: String] = [:]
    /// A photo waiting on the "this original backs a published disclosure"
    /// confirmation before it is deleted (W2-C3).
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
        compare != nil || animatedClip != nil || customEditPhoto != nil || suggestResult != nil
            || showReelStudio || showLibrary || showCamera || showSignIn
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
            VStack(spacing: Theme.spacing) {
                HStack(spacing: 10) {
                    addButton("Add photos", "photo.stack", filled: true) { showLibrary = true }
                    addButton("Take a photo", "camera", filled: false) {
                        if UIImagePickerController.isSourceTypeAvailable(.camera) { showCamera = true }
                    }
                }

                // AI PHOTO STUDIO LEADS WITH PHOTO EDITING. The reel card used to
                // sit here, at the top, above everything — so opening this screen
                // with no photos showed a dominant "Make a reel" poster and a row
                // of inert chips, and the owner's read after the 4,000 sq ft field
                // test was that the photo editing (declutter in particular) had
                // been removed and the button just opened photo-to-reel. The reel
                // card is still ALWAYS on screen and still names the voiceover —
                // it is simply below the photos now, where it belongs.
                if photos.isEmpty && !isProcessing {
                    emptyShowcase
                }

                if isProcessing {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(processingText).foregroundStyle(Theme.inkDim)
                    }
                    .padding(.vertical, 8)
                }

                if !photos.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Tap a photo to see before and after. Tap the wand on a photo to change it.")
                            .font(.rpCaption).foregroundStyle(Theme.inkDim)
                        // W2-C4: the agent learns this BEFORE they tap, not after
                        // a broker asks. Disclosure is automatic, not optional.
                        Label("Every AI edit is disclosed on your tour, and the untouched original is published with it.",
                              systemImage: "checkmark.shield.fill")
                            .font(.rpCaption.weight(.semibold))
                            .foregroundStyle(Theme.good)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                photoGrid

                if !photos.isEmpty {
                    ShareLink(items: photos.map { $0.enhancedURL }) {
                        Label("Share all photos", systemImage: "square.and.arrow.up")
                            .font(.rpBody.weight(.semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(Theme.accent).foregroundStyle(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }

                reelCard

                clipsCard
            }
            .padding()
        }
        .background(Theme.bg)
        .navigationTitle("AI Photo Studio")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { studioTitleBar }
        }
        .onAppear {
            loadExisting()
            syncIdleHold()      // a dismissed cover re-appears mid-animate
            seedPhotosForUIWalk()
        }
        .onChange(of: isProcessing) { _ in syncIdleHold() }
        .onDisappear {
            if !isPresentingOverlay { animateTask?.cancel() }
            releaseIdleHold()   // re-taken by onAppear when the work is still running
        }
    }

    private var studioSheets: some View {
        studioCore
        .sheet(isPresented: $showLibrary) {
            LibraryImagePicker { imgs in ingest(imgs) }.ignoresSafeArea()
        }
        .sheet(isPresented: $showCamera) {
            CameraPicker { img in ingest([img]) }.ignoresSafeArea()
        }
        .sheet(isPresented: $showSignIn) { SignInView.forAI("AI photo edits") }
        .fullScreenCover(item: $compare) { p in
            PhotoCompareView(photo: p, disclosure: editDisclosures[p.id])
        }
        .sheet(item: $animatedClip) { clip in AnimatedClipSheet(clip: clip) }
        .sheet(item: $customEditPhoto) { p in
            CustomEditSheet(photo: p, api: model.api, space: space,
                            listingServerID: listingServerID) { prompt in
                aiEdit(p, "custom", prompt: prompt)
            }
        }
        .sheet(item: $suggestResult) { r in
            SuggestSheet(suggestions: r.suggestions) { edit in
                // stage needs a style — default to modern (the dialog's first).
                if edit == "stage" { aiEdit(r.photo, "stage", style: "modern") }
                else { aiEdit(r.photo, edit) }
            }
        }
        .fullScreenCover(isPresented: $showReelStudio) {
            // The listing's aerial intro rides along as a ready-made lead clip,
            // the same way `AerialIntroSheet` passes its own. Without this the
            // aerial could ONLY open a reel from inside the aerial sheet — and the
            // path most people take is the listing's "Make a reel" card, which
            // lands here, so in the 4,000 sq ft field test the aerial silently
            // could not be used as a reel intro at all.
            ReelStudioView(listing: listing, photos: photos,
                           extraClipURLs: aerialClipURLs)
                .environmentObject(model)
        }
    }

    var body: some View {
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
            Text("Each change saves as a new photo. The original stays, and the change is disclosed on your tour.")
        }
        // W2-C3: a photo's "before" is the file a published disclosure's
        // "View original" points at. Never destroy it without asking.
        .confirmationDialog("Delete this photo?", isPresented: $showPhotoDeleteConfirm,
                            titleVisibility: .visible, presenting: pendingPhotoDelete) { p in
            Button("Delete photo", role: .destructive) {
                delete(p)
                pendingPhotoDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingPhotoDelete = nil }
        } message: { _ in
            Text(space == .realEstate
                 ? "This deletes the edited photo AND the untouched original beside it. Your published tour discloses AI edits and links buyers to the original — download the originals from COMPLIANCE first if your broker needs them on file."
                 : "This deletes the edited photo AND the untouched original beside it. Your published tour discloses AI edits and links \(space.customerNoun) to the original — download the originals from COMPLIANCE first if you want to keep them on file.")
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
        .confirmationDialog("Pick a style", isPresented: $showStageDialog,
                            titleVisibility: .visible, presenting: stagePhoto) { p in
            Button("Modern") { aiEdit(p, "stage", style: "modern") }
            Button("Rustic") { aiEdit(p, "stage", style: "rustic") }
            Button("Minimalist") { aiEdit(p, "stage", style: "minimalist") }
            Button("Scandinavian") { aiEdit(p, "stage", style: "scandinavian") }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            // `stagingLabel` is the INDUSTRY term ("Virtual staging" /
            // "Furnish & style") — the button says "Add furniture", the
            // disclosure sentence says what a broker has to read.
            Text("AI adds furniture in the style you pick. Walls and windows stay as they are. \(stagingLabel) is disclosed on your tour.")
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
                Button("Sign in") { showSignIn = true }
            }
            Button("OK", role: .cancel) { aiFailure = nil }
        } message: { f in
            Text(f.fullMessage)
        }
        // Guideline 5.1.2(i): every edit on this screen ships the photo to a
        // third-party model (Gemini for stills, Seedance for photo→clip), so
        // the disclosure has to be agreed BEFORE the screen can be used. Asked
        // once per device; declining backs out of the studio.
        .aiConsentGate()
        .task {
            if await AIConsent.shared.ensureGranted() == false { dismiss() }
        }
    }

    private var photoGrid: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(photos) { p in
                // Wand overlay is a SIBLING of the thumb button (a Button
                // inside another Button's label never gets the tap).
                ZStack(alignment: .bottomTrailing) {
                    Button { compare = p } label: { thumb(p) }
                        .buttonStyle(ScalePressStyle())
                        .accessibilityLabel(Text("Photo — opens before-and-after compare"))
                        .contextMenu { photoMenu(p) }
                    wandButton(p)
                }
            }
        }
        // New AI edits and deletions settle into the grid instead of
        // popping — keyed on count so only inserts/removes animate.
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: photos.count)
    }

    @ViewBuilder private func photoMenu(_ p: EnhancedPhoto) -> some View {
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
                Button { aiEdit(p, "stage", style: "scandinavian") } label: { Text("Scandinavian") }
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
        Button { setMain(p) } label: {
            Label("Use as cover photo", systemImage: "star")
        }
        Button(role: .destructive) { confirmDelete(p) } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    // MARK: - AI calls (all gated on sign-in; every call runs on the user's account)

    /// Present the sign-in sheet instead of letting the call 401 (F-A-13).
    private func requireSignIn() -> Bool {
        if Config.enableAuth && !auth.isSignedIn {
            showSignIn = true
            return false
        }
        return true
    }

    private func openCustomEdit(_ p: EnhancedPhoto) {
        guard requireSignIn() else { return }
        customEditPhoto = p
    }

    /// AI edit (twilight | sky | lawn | declutter | stage | custom) via the
    /// `ai-photo` edge function. `style` rides along for stage, `prompt` for
    /// custom. Saves the result as a NEW photo (keeps the original) and opens
    /// the before/after. One job at a time (re-entrancy guard, F-A-22); the
    /// JPEG work runs off the main actor.
    ///
    /// COMPLIANCE (W2-C3). Before the edit runs we publish the UNTOUCHED
    /// original with `role:"original"` and send its asset id as
    /// `original_asset_id`, so the disclosure block's "View original" link is a
    /// real file rather than a dead promise — California AB 723 requires access
    /// to the unaltered version, not only the sentence. Both that upload and the
    /// server-listing creation it needs are best effort: an agent's edit never
    /// fails because the audit log couldn't be anchored.
    ///
    /// A `400 unsupported_edit` from the fair-housing denylist surfaces the
    /// server's own wording and is NEVER auto-retried — the user re-words it.
    private func aiEdit(_ p: EnhancedPhoto, _ edit: String,
                        style: String? = nil, prompt: String? = nil) {
        guard !isProcessing else { return }
        guard requireSignIn() else { return }
        isProcessing = true
        processingText = "Working on your photo…"
        let api = model.api          // snapshot on the main actor
        let targetDir = dir
        let source = p.enhancedURL
        // The unaltered "before" we publish for disclosure. `originalURL` is the
        // camera/ingest original when one exists; for an already-AI-edited photo
        // it is that edit's own recorded source. Never a different photo's file.
        // …but only when it really IS a separate file. When the "before" copy is
        // missing, `originalURL` falls back to the photo itself — publishing that
        // as "the original" would label an already-processed image unaltered, so
        // we publish nothing and the compliance row honestly shows amber.
        let unaltered: URL? = p.originalURL.standardizedFileURL == p.enhancedURL.standardizedFileURL
            ? nil : p.originalURL
        let listingLocalID = listing.id
        let isSample = listing.isSample
        let disclosureLabel = Self.provenanceLabel(edit: edit, style: style, space: space)
        let spaceRaw = space.rawValue    // THIS listing's type, not the selected one (P2-5)
        let tapKey = UUID().uuidString   // one idempotency key per user tap
        Task {
            do {
                guard let b64 = await AIImagePrep.jpegBase64(at: source, maxDimension: 2048, quality: 0.9) else {
                    throw AIImagePrep.error("Couldn't read that photo.")
                }
                // Anchor + "before", both best effort.
                var serverListingID: UUID? = nil
                var originalAssetID: String? = nil
                if !isSample {
                    serverListingID = await model.serverListingIDForCompliance(listingLocalID)
                    if let sid = serverListingID, let unaltered {
                        await MainActor.run { processingText = "Saving the original for disclosure…" }
                        originalAssetID = await model.publishOriginalForDisclosure(
                            listingServerID: sid, fileURL: unaltered)
                        await MainActor.run { processingText = "Working on your photo…" }
                    }
                }

                var request = AIPhotoEditRequest(imageBase64: b64, mime: "image/jpeg", edit: edit)
                request.style = style
                request.prompt = prompt
                request.spaceType = spaceRaw
                request.listingServerID = serverListingID
                request.label = disclosureLabel
                request.originalAssetID = originalAssetID
                request.idempotencyKey = tapKey
                let result = try await api.aiPhotoEdit(request)
                // Save with the same enh-/orig- convention as ingested photos: a
                // UUID-named PNG was skipped by loadExisting (enh- filter) and lost
                // on relaunch. Timestamp id sorts newest-first alongside ingests;
                // the copied "before" keeps the compare working after relaunch.
                let id = String(format: "%015d", Int(Date().timeIntervalSince1970 * 1000))
                    + "-" + String(UUID().uuidString.prefix(4))
                let outURL = targetDir.appendingPathComponent("enh-\(id).jpg")
                guard await AIImagePrep.writeJPEG(base64: result.imageBase64, to: outURL, quality: 0.95) else {
                    throw AIImagePrep.error("The AI didn't return an image. Try again.")
                }
                let beforeURL = targetDir.appendingPathComponent("orig-\(id).jpg")
                try? FileManager.default.copyItem(at: source, to: beforeURL)
                // Never point originalURL at another photo's live file — delete()
                // removes it, so fall back to self, not the source, if the copy fails.
                let originalURL = FileManager.default.fileExists(atPath: beforeURL.path)
                    ? beforeURL : outURL
                let disclosure = result.disclosure
                await MainActor.run {
                    let newPhoto = EnhancedPhoto(id: id, originalURL: originalURL, enhancedURL: outURL)
                    photos.insert(newPhoto, at: 0)
                    if let disclosure, !disclosure.isEmpty { editDisclosures[id] = disclosure }
                    isProcessing = false
                    Haptics.success()
                    compare = newPhoto   // show the before/after (and its disclosure)
                    Analytics.track("ai_photo_edit", ["task": edit, "ok": "true"])
                    if !isSample { FirstProjectGuide.recordAIPhotoEditCompleted() }
                }
                // Publish the "after" against the same provenance row so the
                // tour can show the pair side by side (NorthstarMLS). Off the
                // critical path — the edit is already on screen, and a failure
                // costs nothing: the original alone satisfies AB 723.
                if let provenanceID = result.provenanceID, let sid = serverListingID {
                    await model.attachAlteredPhotoForDisclosure(
                        provenanceID: provenanceID, listingServerID: sid, fileURL: outURL)
                }
            } catch {
                await MainActor.run {
                    isProcessing = false
                    // The fair-housing denylist speaks for itself — show its
                    // wording, let the user re-word, never retry automatically.
                    let title = (error as? APIError)?.code == "unsupported_edit"
                        ? "That change isn't allowed" : "That change didn't work"
                    aiFailure = AIFailure(error, title: title)
                }
            }
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
        guard requireSignIn() else { return }
        isProcessing = true
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
                    isProcessing = false
                    suggestResult = SuggestResult(photo: p, suggestions: results)
                    Haptics.success()
                }
            } catch {
                await MainActor.run {
                    isProcessing = false
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
        guard requireSignIn() else { return }
        isProcessing = true
        processingText = "Making your video — about a minute…"
        Haptics.selection()
        let api = model.api          // snapshot on the main actor
        let targetDir = dir
        let source = p.enhancedURL
        let photoID = p.id
        let listingLocalID = listing.id
        let isSample = listing.isSample
        let tapKey = UUID().uuidString
        animateTask = Task {
            do {
                guard let b64 = await AIImagePrep.jpegBase64(at: source, maxDimension: 1280, quality: 0.85) else {
                    throw AIImagePrep.error("Couldn't read that photo.")
                }
                // Generated motion is altered media too (Wisconsin Act 69 covers
                // generated video from 1 Jan 2027) — anchor it so it is
                // disclosed and audited like every other AI asset.
                var serverListingID: UUID? = nil
                if !isSample {
                    serverListingID = await model.serverListingIDForCompliance(listingLocalID)
                }
                let job = try await api.aiVideoReelClip(
                    imageBase64: b64, mime: "image/jpeg",
                    prompt: nil, seconds: 5,
                    listingServerID: serverListingID, label: "Animated photo",
                    idempotencyKey: tapKey)

                let deadline = Date().addingTimeInterval(10 * 60)
                var remoteURL: URL?
                while remoteURL == nil {
                    guard Date() < deadline else {
                        throw AIImagePrep.error("The clip took too long. Please try again.")
                    }
                    try await Task.sleep(nanoseconds: 6_000_000_000)
                    switch try await api.aiVideoStatus(job) {
                    case .processing:
                        break   // keep waiting; the grid shows the in-flight label
                    case .completed(let videoURL):
                        remoteURL = videoURL
                    case .failed(let message):
                        throw AIImagePrep.error(message)
                    }
                }
                guard let remoteURL else {
                    throw AIImagePrep.error("The AI didn't return a clip. Try again.")
                }

                let (tmp, resp) = try await URLSession.shared.download(from: remoteURL)
                if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw AIImagePrep.error("Couldn't download the finished clip (HTTP \(http.statusCode)). Try again.")
                }
                let dest = targetDir.appendingPathComponent(
                    "clip-\(photoID)-\(UUID().uuidString.prefix(4)).mp4")
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tmp, to: dest)

                await MainActor.run {
                    isProcessing = false
                    clips = SavedClip.loadAll(listingID: listingLocalID)   // the new clip joins the list
                    animatedClip = AnimatedClip(url: dest)
                    Haptics.success()
                }
            } catch is CancellationError {
                // The studio was left mid-animate — stop polling quietly, and
                // never leave the spinner up (F-A-12).
                await MainActor.run { isProcessing = false }
            } catch {
                await MainActor.run {
                    isProcessing = false
                    aiFailure = AIFailure(error, title: "Couldn't animate the photo")
                }
            }
        }
    }

    // MARK: - Pieces

    private func thumb(_ p: EnhancedPhoto) -> some View {
        DetailPhotoThumb(url: p.enhancedURL, height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border))
            .overlay(alignment: .topLeading) {
                if isMain(p) {
                    Label("Cover", systemImage: "star.fill")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Theme.accent, in: Capsule())
                        .foregroundStyle(Color.white)
                        .padding(8)
                }
            }
    }

    private func addButton(_ title: String, _ icon: String, filled: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.rpBody.weight(.semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 13)
                .background(filled ? Theme.accent : Theme.accentSoft)
                .foregroundStyle(filled ? Color.white : Theme.accent)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
            Text("AI Photo Studio")
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

    /// Photos need at least two frames before there is anything to stitch.
    private var canMakeReel: Bool { photos.count >= 2 }

    /// The reel maker — ALWAYS visible, from zero photos, so the feature (and
    /// the voice + captions inside it) is named before anyone taps anything.
    /// Disabled until two photos exist, with the reason said plainly.
    @ViewBuilder private var reelCard: some View {
        Button { showReelStudio = true } label: { reelCardFace }
            .buttonStyle(ScalePressStyle())
            .disabled(!canMakeReel)
            .accessibilityIdentifier("detail.reelStudio")
            .accessibilityLabel(Text(canMakeReel
                                     ? "Make a reel. Your photos become a video with your voice and captions."
                                     : "Make a reel. Add 2 photos to start."))
    }

    private var reelCardFace: some View {
        VStack(alignment: .leading, spacing: 10) {
            reelCardHeader
            reelVoiceCallout
            Text(canMakeReel ? "Ready — \(photos.count) photos" : "Add 2 photos to start")
                .font(.rpCaption.weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.95))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RPGradient.reel)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        // Arrived by tapping "Make a reel" on the listing? Ring the card the
        // deep link was aiming at, so it is unmistakably the thing to tap.
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .strokeBorder(Color.white.opacity(intent == .reel ? 0.85 : 0), lineWidth: 2)
        )
        .opacity(canMakeReel ? 1 : 0.55)
    }

    private var reelCardHeader: some View {
        HStack(spacing: 14) {
            Image(systemName: "film.stack")
                .font(.system(size: 22, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.white)
                .frame(width: 48, height: 48)
                .background(Color.white.opacity(0.18),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Make a reel").font(.rpHeadline).foregroundStyle(Color.white)
                    AIPill()
                }
                Text("Your photos become a video — add your voice and captions.")
                    .font(.rpCaption).foregroundStyle(Color.white.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 8)
            if canMakeReel {
                Image(systemName: "chevron.right")
                    .font(.rpCaption.weight(.bold)).foregroundStyle(Color.white.opacity(0.9))
            }
        }
    }

    /// Names the voiceover where the agent actually stands. Before this, the
    /// word "voice" appeared nowhere until two photos and a tap later.
    private var reelVoiceCallout: some View {
        Text("🎙 Voice + captions")
            .font(.rpCaption.weight(.semibold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.white.opacity(0.18), in: Capsule())
    }

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

    /// Empty state = a menu of what the AI can do for THIS kind of space, not a
    /// blank box (a gym never sees "green lawn").
    private var emptyShowcase: some View {
        VStack(spacing: 14) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 32, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.white)
                .frame(width: 64, height: 64)
                .background(RPGradient.photo,
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            Text("Add a photo")
                .font(.rpHeadline).foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
            Text(space == .realEstate
                 ? "Then tap one button to fix the sky, clean the room, or stage it."
                 : "Then tap one button to fix the sky, tidy the space, or furnish it.")
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
                .multilineTextAlignment(.center)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8),
                                GridItem(.flexible(), spacing: 8)], spacing: 8) {
                showcaseChip("moon.stars.fill", EditWords.twilight, "twilight")
                showcaseChip("cloud.sun.fill", EditWords.sky, "sky")
                if space == .realEstate {
                    showcaseChip("leaf.fill", EditWords.lawn, "lawn")
                }
                showcaseChip("sparkles.rectangle.stack.fill", EditWords.declutter, "declutter",
                             sub: EditWords.declutterGloss)
                showcaseChip("sofa.fill", EditWords.stage(space), "stage")
                showcaseChip("play.rectangle.on.rectangle.fill", EditWords.animate, "animate")
                if space != .realEstate {
                    showcaseChip("text.bubble.fill", EditWords.custom, "custom")
                }
            }
        }
        .padding(.vertical, 22)
    }

    /// One TAPPABLE edit in the empty state.
    ///
    /// This was a plain `HStack` — a poster of what the AI could do with no way to
    /// do any of it. In the 4,000 sq ft field test that row of decorations was the
    /// first thing under a dominant "Make a reel" card, and nothing in it
    /// responded to a tap, which is how "AI Photo Studio just opens the
    /// photo-to-reel feature" became the honest description of the screen.
    ///
    /// Now it picks a photo and applies that edit to it. `sub` is the plain-words
    /// gloss under the feature's real name (see `EditWords.declutter`).
    private func showcaseChip(_ icon: String, _ label: String, _ edit: String,
                              sub: String? = nil) -> some View {
        Button { startShowcaseEdit(edit) } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.rpCaption.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if let sub {
                        Text(sub)
                            .font(.caption2)
                            .foregroundStyle(Theme.inkDim)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(ScalePressStyle())
        .disabled(isProcessing)
        .accessibilityLabel(Text("\(label). Pick a photo and this change is made to it."))
    }

    /// A chip was tapped with no photos on screen: open the picker and remember
    /// the edit, so the photo the agent chooses gets it immediately.
    ///
    /// EVERY GATE STAYS WHERE IT WAS. Sign-in is checked here, before the picker
    /// opens, through the same `requireSignIn()` that `aiEdit`, `animate` and
    /// `openCustomEdit` call — and it is checked AGAIN by whichever of those
    /// actually runs. The AI-consent gate (`.aiConsentGate()` on this view's body)
    /// and the quota/paywall path (`AIFailure.isQuota` → `PaywallRouter`) are
    /// untouched: this adds a way to reach `aiEdit`, not a way around it.
    private func startShowcaseEdit(_ edit: String) {
        guard !isProcessing else { return }
        guard requireSignIn() else { return }
        pendingShowcaseEdit = edit
        showLibrary = true
        Haptics.selection()
    }

    /// Run the edit a chip asked for, now that a photo exists. Called from
    /// `ingest` AFTER `isProcessing` is cleared, so `aiEdit`'s one-job-at-a-time
    /// guard (F-A-22) lets it through.
    private func runPendingShowcaseEdit() {
        guard let edit = pendingShowcaseEdit else { return }
        pendingShowcaseEdit = nil
        guard let target = photos.first else { return }
        switch edit {
        case "animate":
            animate(target)
        case "stage":
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

    // MARK: - Files

    private func loadExisting() {
        photos = EnhancedPhoto.loadAll(listingID: listing.id)
        clips = SavedClip.loadAll(listingID: listing.id)
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

    private func ingest(_ images: [UIImage]) {
        // An empty callback means the picker was cancelled (PHPicker still calls
        // back with no results). Drop any chip's pending edit rather than firing
        // it at the next photo the agent adds for some other reason.
        guard !images.isEmpty else {
            pendingShowcaseEdit = nil
            return
        }
        isProcessing = true
        processingText = "Working on your photo…"
        let targetDir = dir
        DispatchQueue.global(qos: .userInitiated).async {
            for img in images {
                // One pool PER PHOTO: the CIContext render and the two JPEG
                // encodes each leave large autoreleased buffers behind, and
                // holding fifteen of them until the loop ended was the studio's
                // worst memory spike (F-A-19).
                autoreleasepool {
                    let id = String(format: "%015d", Int(Date().timeIntervalSince1970 * 1000))
                        + "-" + String(UUID().uuidString.prefix(4))
                    let enhanced = PhotoEnhancer.enhance(img)
                    if let od = img.jpegData(compressionQuality: 0.95) {
                        try? od.write(to: targetDir.appendingPathComponent("orig-\(id).jpg"))
                    }
                    if let ed = enhanced.jpegData(compressionQuality: 0.95) {
                        try? ed.write(to: targetDir.appendingPathComponent("enh-\(id).jpg"))
                    }
                }
            }
            DispatchQueue.main.async {
                loadExisting()
                // First photos added become the card's cover image automatically.
                if mainRelPath == nil, let first = photos.first { setMain(first) }
                isProcessing = false
                // An empty-state chip may have been waiting on this photo.
                runPendingShowcaseEdit()
            }
        }
    }

    /// Delete one stored motion clip. Nothing else points at the file, so this
    /// is unconditional — the confirmation happens at the call site.
    private func deleteClip(_ clip: SavedClip) {
        try? FileManager.default.removeItem(at: clip.url)
        loadExisting()
    }

    /// Deleting a photo also deletes its "before". Once the tour is published
    /// that before may be the original a disclosure links to (W2-C3), so ask
    /// first; an unpublished listing deletes straight away as before.
    private func confirmDelete(_ p: EnhancedPhoto) {
        let published = model.listings.first(where: { $0.id == listing.id })?.serverShareURL != nil
        let hasSeparateOriginal = p.originalURL.standardizedFileURL != p.enhancedURL.standardizedFileURL
        guard published, hasSeparateOriginal, !listing.isSample else {
            delete(p)
            return
        }
        pendingPhotoDelete = p
        showPhotoDeleteConfirm = true
    }

    private func delete(_ p: EnhancedPhoto) {
        let wasMain = isMain(p)
        ImageThumbnails.invalidate(p.enhancedURL)
        try? FileManager.default.removeItem(at: p.enhancedURL)
        try? FileManager.default.removeItem(at: p.originalURL)
        editDisclosures.removeValue(forKey: p.id)
        loadExisting()
        if wasMain {
            model.setMainPhoto(photos.first.map { FileStore.relativePath(for: $0.enhancedURL) }, for: listing.id)
        }
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

/// Full-screen before/after compare. Both images decode once, off the main
/// thread, at screen resolution.
struct PhotoCompareView: View {
    let photo: EnhancedPhoto
    /// The exact disclosure sentence the server recorded for this edit, when it
    /// came from one (W2-C4). Shown VERBATIM — it is the sentence the public
    /// tour prints, and the agent should recognise it when a broker quotes it.
    var disclosure: String? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var showOriginal = false
    @State private var enhanced: UIImage?
    @State private var original: UIImage?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack {
                Spacer()
                if let ui = showOriginal ? original : enhanced {
                    Image(uiImage: ui).resizable().scaledToFit()
                        .accessibilityLabel(Text(showOriginal ? "Original photo" : "Enhanced photo"))
                } else {
                    ProgressView().tint(.white)
                }
                Spacer()
                if let disclosure, !disclosure.isEmpty {
                    Label(disclosure, systemImage: "checkmark.shield.fill")
                        .font(.rpCaption)
                        .foregroundStyle(Color.white.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 20)
                        .padding(.top, 6)
                        .accessibilityLabel(Text("Disclosure published with this photo. \(disclosure)"))
                }
                Picker("", selection: $showOriginal) {
                    Text("After").tag(false)
                    Text("Before").tag(true)
                }
                .pickerStyle(.segmented)
                .padding()
            }
            VStack {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title).foregroundStyle(Color.white.opacity(0.9))
                    }
                    .padding()
                    .accessibilityLabel(Text("Close"))
                }
                Spacer()
            }
        }
        // Media viewer — always dark chrome (segmented control, buttons),
        // regardless of the app's light/dark appearance. The photo sits on
        // black in both modes anyway.
        .environment(\.colorScheme, .dark)
        .task {
            let after = await AIImagePrep.decoded(at: photo.enhancedURL, maxPixel: 2400)
            enhanced = after
            if photo.originalURL == photo.enhancedURL {
                original = after
            } else {
                original = await AIImagePrep.decoded(at: photo.originalURL, maxPixel: 2400)
            }
        }
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
    @State private var isImproving = false       // "Improve my prompt" in flight
    @State private var improveError: String?
    /// The area named by the starter chip the person tapped, sent as
    /// `room_hint`. See `StarterChip` for why this is the room signal we have.
    @State private var pickedArea: String?

    private var trimmed: String {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("Tell the AI what to change — it edits this photo and keeps the original.")
                    .font(.rpBody)
                    .foregroundStyle(Theme.inkDim)

                TextField("Describe the change — e.g. 'make it look freshly painted white with warm evening light'",
                          text: $prompt, axis: .vertical)
                    .lineLimit(4...8)
                    .textFieldStyle(.roundedBorder)

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
                    .background(Theme.accentSoft).foregroundStyle(Theme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .disabled(trimmed.isEmpty || isImproving)
                Text("Rewrites the first 300 characters of your idea into a sharper prompt.")
                    .font(.rpCaption)
                    .foregroundStyle(Theme.inkDim)

                if let improveError {
                    Text(improveError)
                        .font(.rpCaption)
                        .foregroundStyle(Theme.warn)
                }

                Button {
                    let text = String(trimmed.prefix(600))
                    Haptics.selection()
                    dismiss()
                    onGenerate(text)
                } label: {
                    Label("Generate", systemImage: "wand.and.stars")
                        .font(.rpBody.weight(.semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(Theme.accent).foregroundStyle(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .disabled(trimmed.isEmpty || isImproving)

                Spacer()
            }
            .padding()
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
                // An emptied box means the starter chip that named an area is
                // gone too: whatever gets typed next may be about a different
                // room, and a stale `room_hint` is worse than none.
                if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    pickedArea = nil
                }
            }
        }
        .presentationDetents([.medium, .large])
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
                            text: "Clear everything off the kitchen counters and make the surfaces look freshly wiped. Keep the cabinets, appliances and layout exactly as photographed."),
                StarterChip(label: "Fresh white walls", area: nil,
                            text: "Repaint the walls a clean warm white and touch up the trim, keeping every window, fixture and piece of furniture exactly where it is."),
                StarterChip(label: "Warm evening light", area: "Living Room",
                            text: "Relight the room with warm evening light coming through the windows, keeping the furniture and the architecture exactly as photographed."),
                StarterChip(label: "Tidy the yard", area: "Backyard",
                            text: "Tidy the yard: clear the hose, bins and loose items, and make the beds look freshly mulched. Keep the house and the planting exactly as photographed."),
                StarterChip(label: "Empty the driveway", area: "Exterior",
                            text: "Remove the cars and the bins from the driveway and the street in front, keeping the house exactly as photographed."),
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
                StarterChip(label: "Fresh white walls", area: nil,
                            text: "Repaint the walls a clean warm white and touch up the trim, keeping every window and fixture exactly where it is."),
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
                let improved = try await api.aiImprovePrompt(rough: String(rough.prefix(300)),
                                                             roomHint: hint,
                                                             listingServerID: serverID)
                let text = String(improved.prefix(600))
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
                await MainActor.run {
                    isImproving = false
                    improveError = why
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
                    .background(Theme.accent).foregroundStyle(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                    .background(Theme.accentSoft).foregroundStyle(Theme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
    @State private var showSignIn = false
    @State private var showLibrary = false
    @State private var showCamera = false
    @State private var showCloseConfirm = false
    @State private var showReelStudio = false
    @State private var geocoder = CLGeocoder()

    private var signedIn: Bool { !Config.enableAuth || auth.isSignedIn }
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
                                      retryHint: "Adjust the settings above and generate again.",
                                      quotaFeature: "aerials",
                                      onSignIn: { showSignIn = true })
                    }
                }
                .padding()
            }
            .background(Theme.bg)
            .navigationTitle("Aerial intro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        if isGenerating { showCloseConfirm = true } else { dismiss() }
                    }
                }
            }
        }
        .interactiveDismissDisabled(isGenerating)
        .onAppear(perform: seedIfNeeded)
        .onDisappear {
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
        .sheet(isPresented: $showSignIn) { SignInView.forAI("aerial intros") }
        .sheet(isPresented: $showLibrary) {
            LibraryImagePicker(selectionLimit: 1) { imgs in
                if let img = imgs.first { saveExterior(img) }
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showCamera) {
            CameraPicker { img in saveExterior(img) }.ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $showReelStudio) {
            ReelStudioView(listing: listing,
                           photos: EnhancedPhoto.loadAll(listingID: listing.id),
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
            Text(hasPhoto
                 ? "A cinematic AI opening shot for this \(noun) — generated from your exterior photo, so it starts on the real building and flies out."
                 : "A cinematic AI opening shot for this \(noun). Add an exterior photo below and it starts on YOUR building; without one the AI invents a generic \(noun).")
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

    // The form is ALWAYS visible for a real listing — an agent must be able to
    // pick the exterior photo and set the shot up before being asked to sign in
    // (a sign-in wall in front of the whole form hides the one thing that makes
    // the aerial actually depict THIS property). Only the action is gated.
    @ViewBuilder private var formSection: some View {
        if listing.isSample {
            sampleNotice
        } else {
            propertyCard
            lookCard
            formatCard
            if signedIn {
                generateButton
            } else {
                signInBlock
            }
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

    private var signInBlock: some View {
        VStack(spacing: 10) {
            Label("Set the shot up above, then sign in to generate — the AI runs on your account.",
                  systemImage: "person.crop.circle.badge.exclamationmark")
                .font(.rpBody)
                .foregroundStyle(Theme.inkDim)
                .multilineTextAlignment(.center)
            Button { showSignIn = true } label: {
                Text("Sign in")
                    .font(.rpBody.weight(.semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 13)
                    .background(Theme.accentSoft).foregroundStyle(Theme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(.vertical, 6)
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
                            if UIImagePickerController.isSourceTypeAvailable(.camera) { showCamera = true }
                        } label: {
                            Label("Take photo", systemImage: "camera")
                        }
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
                .background(hasPhoto ? Theme.accent : Theme.warn)
                .foregroundStyle(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .disabled(isSavingPhoto)
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
                        .background(Theme.accent).foregroundStyle(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                        .background(Theme.accentSoft).foregroundStyle(Theme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                        .background(Theme.accentSoft).foregroundStyle(Theme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            if let saveError {
                Text(saveError)
                    .font(.rpCaption)
                    .foregroundStyle(Theme.warn)
                    .multilineTextAlignment(.center)
            }
            Button("Regenerate") {
                failure = nil
                phase = .form      // the current clip stays until a new one lands
            }
            .font(.rpBody)
            .foregroundStyle(Theme.inkDim)
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
        guard !isSavingPhoto else { return }
        isSavingPhoto = true
        photoError = nil
        let listingID = listing.id
        let dest = EnhancedPhoto.directory(for: listingID).appendingPathComponent("exterior.jpg")
        Task {
            let ok = await AIImagePrep.writeJPEG(image, to: dest, maxDimension: 2560, quality: 0.9)
            await MainActor.run {
                isSavingPhoto = false
                guard ok else {
                    photoError = "Couldn't save that photo. Try another one."
                    return
                }
                ImageThumbnails.invalidate(dest)
                model.setExteriorPhoto(FileStore.relativePath(for: dest), for: listingID)
                exteriorURL = dest
                exteriorVersion = UUID()
                Haptics.success()
            }
        }
    }

    // MARK: - Generate (submit → poll → download; fal URLs expire, so download now)

    private func generate() {
        guard signedIn, phase != .generating, !listing.isSample, !isSavingPhoto else { return }
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
private struct PendingReelClips: Codable {
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

    /// The parked set, or nil when there is nothing to resume. A record whose
    /// files have gone (Clear local data, a listing delete) clears itself rather
    /// than offering a resume that would stitch nothing.
    static func load(for id: UUID) -> PendingReelClips? {
        guard let data = UserDefaults.standard.data(forKey: key(id)),
              let parked = try? JSONDecoder().decode(PendingReelClips.self, from: data) else { return nil }
        guard !parked.clipURLs.isEmpty else {
            clear(for: id)
            return nil
        }
        return parked
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.key(listingID))
    }

    /// Forget the record AND delete the parked mp4s. Only ever called once the
    /// clips are inside a finished reel, or when the agent said to discard them.
    static func clear(for id: UUID) {
        UserDefaults.standard.removeObject(forKey: key(id))
        try? FileManager.default.removeItem(at: directory(for: id))
    }
}

// MARK: - Reel Studio (multi-photo → AI motion clips → one stitched social video)
// Pick 2–8 listing photos; each becomes a 5 s Seedance motion clip via
// POST /ai-video/reel-clip (sequential submit → poll → download), then the
// clips are stitched ON-DEVICE with AVFoundation into a single 9:16 or 16:9
// mp4 saved to Documents/reels/. `extraClipURLs` (e.g. the listing's aerial
// intro) are ready-made clips that lead the reel — no AI call for those.
// Inline here per the new-file-not-in-target rule.

struct ReelStudioView: View {
    @State private var idleHeld = false
    @EnvironmentObject var model: AppModel
    @ObservedObject private var auth = AuthStore.shared
    @Environment(\.dismiss) private var dismiss
    let listing: Listing
    let photos: [EnhancedPhoto]
    /// Finished clips to put in front of the photo clips (the aerial intro).
    var extraClipURLs: [URL] = []

    private enum Phase { case setup, generating, stitching, done, failed }

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

    @State private var phase: Phase = .setup
    @State private var selected: [String] = []      // photo ids in tap order = clip order
    @State private var selectedExtras: [URL] = []   // extra clips still switched on
    @State private var seededExtras = false
    @State private var portrait = true              // 9:16 (true) vs 16:9 (false)
    @State private var captionsOn = true            // intro title card + Rendprop mark on export
    /// The BIG burned-in words on each shot — three or four, upper case, held for
    /// the picture. On by default and deliberately so: this is what separates a
    /// reel that looks posted from one that looks generated, and the owner's whole
    /// bet is that the app produces the former without being asked.
    @State private var bigCaptionsOn = true
    @State private var bigCaptionStyle: ReelComposer.ShotCaptionStyle = .lowerThird
    /// Defaults to hard cuts, and the copy under the picker says why.
    @State private var reelTransition: ReelComposer.Transition = .cut
    @State private var motionPrompt = ""
    @State private var completedClips = 0
    @State private var totalClips = 0
    @State private var failedClips = 0
    @State private var statusText = ""
    @State private var reelURL: URL?
    @State private var player: AVPlayer?
    @State private var savedToPhotos = false
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var failure: AIFailure?
    @State private var showSignIn = false
    @State private var workTask: Task<Void, Never>?
    /// The newest reel already on disk for this listing (F-A-23). Reels used to
    /// be write-only: the file survived in Documents/reels but the studio always
    /// reopened on an empty setup form, so the last one was unreachable.
    @State private var lastReel: URL?
    /// Clips from an earlier run of THIS listing's reel that were generated and
    /// billed but never stitched (the 4,000 sq ft field test). Loaded on open,
    /// exactly like `AerialIntroSheet` resumes a `PendingAerialJob`.
    @State private var parkedClips: PendingReelClips?
    /// Close was tapped while a job was running — ask before cancelling it, the
    /// way the aerial sheet already does.
    @State private var showCloseConfirm = false
    @State private var showDiscardParkedConfirm = false

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

    private var signedIn: Bool { !Config.enableAuth || auth.isSignedIn }
    private var space: SpaceType { listing.isSample ? SpaceType.current : listing.spaceType }
    /// The screen photos are added on — same words as its title bar.
    private var photosScreenName: String { "AI Photo Studio" }
    private var totalSelected: Int { selectedExtras.count + selected.count }
    private var canGenerate: Bool { totalSelected >= 2 && totalSelected <= 9 }
    /// A job is in flight — AI clips are being generated, or the stitch is
    /// running. Closing now cancels it, so Close asks first (F-A-05 / the
    /// 4,000 sq ft field test).
    private var isWorking: Bool { phase == .generating || phase == .stitching }

    /// Title + which home this reel is for. iOS 16 has no `navigationSubtitle`,
    /// so the two lines are a principal toolbar item.
    private var reelTitleBar: some View {
        VStack(spacing: 1) {
            Text("Reel Studio")
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
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.spacing) {
                    switch phase {
                    case .setup:      setupSection
                    case .generating: generatingSection
                    case .stitching:  stitchingSection
                    case .done:       doneSection
                    case .failed:     failedSection
                    }
                }
                .padding()
            }
            .background(Theme.bg)
            .navigationTitle("Reel Studio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // UNGUARDED Close was half of the money bug: one tap ran
                    // dismiss() → onDisappear → workTask?.cancel(), and the
                    // build's catch deleted every clip already paid for without
                    // a word on screen. Ask, exactly like AerialIntroSheet.
                    Button("Close") {
                        if isWorking { showCloseConfirm = true } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .principal) { reelTitleBar }
            }
        }
        .interactiveDismissDisabled(isWorking)
        .onAppear {
            if !seededExtras {
                selectedExtras = extraClipURLs
                seededExtras = true
            }
            // The tone that suits this trade, picked once. Guarded like
            // `seededExtras` above: onAppear can fire again, and it must not
            // undo a choice the agent made.
            if !seededTone {
                tone = Self.defaultTone(for: space)
                seededTone = true
            }
            lastReel = Self.newestReel(for: listing.id)
            // Pick up clips a previous run generated and was charged for but
            // never stitched — the reel equivalent of resuming a pending aerial.
            if !listing.isSample { parkedClips = PendingReelClips.load(for: listing.id) }
        }
        .onChange(of: phase) { p in
            let wantHold = (p == .generating || p == .stitching)
            if wantHold && !idleHeld { IdleTimer.hold(); idleHeld = true }
            else if !wantHold && idleHeld { IdleTimer.release(); idleHeld = false }
        }
        .onChange(of: voiceMode) { mode in
            // Leaving My voice mid-take drops the mic/session; a finished
            // voiceover is kept. Entering AI voice seeds the script from any
            // recording transcript and loads the voice catalogue once.
            if mode != .myVoice, recorder.isRecording { recorder.cancel() }
            if mode == .aiVoice {
                if aiScript.isEmpty, let t = voiceover?.transcript, !t.isEmpty { aiScript = t }
                loadVoices()
            }
        }
        .onDisappear {
            workTask?.cancel()
            player?.pause()
            voPlayer?.pause()
            if recorder.isRecording { recorder.cancel() }
            if idleHeld { IdleTimer.release(); idleHeld = false }
        }
        .sheet(isPresented: $showSignIn) { SignInView.forAI("reels") }
        .confirmationDialog("Still making your reel", isPresented: $showCloseConfirm,
                            titleVisibility: .visible) {
            Button("Close anyway") {
                workTask?.cancel()
                dismiss()
            }
            Button("Keep waiting", role: .cancel) {}
        } message: {
            Text("Every clip you've already paid for is kept on this phone. Reopen Reel Studio and finish the reel from them — you won't be charged for the same clips twice.")
        }
        .confirmationDialog("Discard these clips?", isPresented: $showDiscardParkedConfirm,
                            titleVisibility: .visible) {
            Button("Discard clips", role: .destructive) { discardParkedClips() }
            Button("Keep them", role: .cancel) {}
        } message: {
            Text("These clips were already generated and already charged. Deleting them means making them again costs another round of AI.")
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
        .aiConsentGate()
        .task {
            if await AIConsent.shared.ensureGranted() == false { dismiss() }
        }
    }

    // MARK: Sections

    // The setup screen is ONE numbered path: 1 pick photos → 2 add your voice
    // (optional) → 3 make the reel. Every step is its own small @ViewBuilder —
    // this file has hit the type-checker's expression budget before, so
    // `setupSection` stays a short list of identifiers and nothing else.
    @ViewBuilder private var setupSection: some View {
        setupHeader

        // Unfinished, ALREADY-PAID-FOR clips come first, and deliberately NOT
        // behind the sign-in pane: stitching them is on-device AVFoundation work
        // with no AI call, so an expired session must never stand between the
        // agent and the reel he has already bought (the 4,000 sq ft field test).
        parkedClipsCard

        // The reel this listing ALREADY has, also outside the gate and for the
        // same reason: it is a finished mp4 on this phone that has already been
        // paid for. Playing, saving or sharing it costs nothing and calls
        // nothing, so an expired session must not put it behind a sign-in wall —
        // the same rule the listing screen's FILES section follows.
        lastReelCard

        if signedIn {
            if !extraClipURLs.isEmpty { clipsCard }
            stepPhotosCard
            stepVoiceCard
            stepMakeCard
        } else {
            signInPane
        }
    }

    private var setupHeader: some View {
        VStack(spacing: 10) {
            Image(systemName: "film.stack")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.accent)
            Text("Make a reel")
                .font(.rpTitle)
                .foregroundStyle(Theme.ink)
            Text(extraClipURLs.isEmpty
                 ? "Your photos become one video for Reels, TikTok or YouTube. Three steps."
                 : "Your aerial intro opens the reel, then your photos. Three steps.")
                .font(.rpBody)
                .foregroundStyle(Theme.inkDim)
                .multilineTextAlignment(.center)
            stepsRail
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    /// The whole flow on one line, so the voice step is visible before you
    /// scroll to it.
    private var stepsRail: some View {
        HStack(spacing: 6) {
            stepChip("1", "Photos")
            Image(systemName: "arrow.right")
                .font(.caption2.weight(.bold)).foregroundStyle(Theme.inkDim)
            stepChip("2", "🎙 Voice")
            Image(systemName: "arrow.right")
                .font(.caption2.weight(.bold)).foregroundStyle(Theme.inkDim)
            stepChip("3", "Make it")
        }
        .padding(.top, 2)
    }

    private func stepChip(_ number: String, _ title: String) -> some View {
        Text("\(number) · \(title)")
            .font(.rpCaption.weight(.semibold))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Theme.accentSoft, in: Capsule())
    }

    /// A numbered step heading. One per card, so nobody has to guess the order.
    private func stepTitle(_ number: Int, _ title: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("STEP \(number) · \(title)")
                .font(.rpKicker).foregroundStyle(Theme.accent)
            Text(note)
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // --- Step 1: photos ---

    private var stepPhotosCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                stepTitle(1, "PICK PHOTOS", "Tap them in the order you want them. 2 to 8.")
                Text("\(selected.count)/8")
                    .font(.rpCaption)
                    .foregroundStyle(selected.count >= 1 ? Theme.accent : Theme.inkDim)
            }
            photoPickerGrid
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    @ViewBuilder private var photoPickerGrid: some View {
        if photos.isEmpty {
            Text("No photos yet — add some in \(photosScreenName) first.")
                .font(.rpCaption)
                .foregroundStyle(Theme.inkDim)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            LazyVGrid(columns: selectColumns, spacing: 8) {
                ForEach(photos) { p in selectThumb(p) }
            }
        }
    }

    // --- Step 3: shape + the button ---

    private var stepMakeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepTitle(3, "MAKE THE REEL", "Pick the shape, then tap the button.")
            formatRow
            titleCardToggle
            bigCaptionsRow
            transitionRow
            motionRow
            makeButton
            aiDisclosureLine
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
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
                Text("Blend").tag(ReelComposer.Transition.dissolve)
                Text("Whip").tag(ReelComposer.Transition.whip)
            }
            .pickerStyle(.segmented)
            Text("Cut is what the pros use — it's the default for a reason.")
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var formatRow: some View {
        Picker("Shape", selection: $portrait) {
            Text("Tall · 9:16").tag(true)
            Text("Wide · 16:9").tag(false)
        }
        .pickerStyle(.segmented)
    }

    private var titleCardToggle: some View {
        Toggle(isOn: $captionsOn) {
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

    private var motionRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("HOW IT MOVES (OPTIONAL)")
                .font(.rpKicker).foregroundStyle(Theme.inkDim)
            TextField("e.g. 'slow push-in, golden-hour feel'",
                      text: $motionPrompt, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
            Text("Leave it blank for a smooth push-in.")
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
            Text(costText)
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var makeButton: some View {
        Button { generate() } label: {
            Label(generateTitle, systemImage: "sparkles")
                .font(.rpBody.weight(.semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 16)
                .background(canGenerate ? Theme.accent : Theme.fillSubtle)
                .foregroundStyle(canGenerate ? Color.white : Theme.inkDim)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .disabled(!canGenerate)
    }

    private var aiDisclosureLine: some View {
        Text("Made with AI motion — the photos themselves are unchanged. Any aerial clip is AI-generated scenery, not real drone footage.")
            .font(.rpCaption)
            .foregroundStyle(Theme.inkDim)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var signInPane: some View {
        VStack(spacing: 10) {
            Label("Sign in to make reels — the AI runs on your account.",
                  systemImage: "person.crop.circle.badge.exclamationmark")
                .font(.rpBody)
                .foregroundStyle(Theme.inkDim)
                .multilineTextAlignment(.center)
            Button { showSignIn = true } label: {
                Text("Sign in")
                    .font(.rpBody.weight(.semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 13)
                    .background(Theme.accentSoft).foregroundStyle(Theme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(.vertical, 6)
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
                    Text("UNFINISHED REEL").font(.rpKicker).foregroundStyle(Theme.accent)
                    Spacer(minLength: 8)
                    Text("\(parkedClipCount) clip\(parkedClipCount == 1 ? "" : "s")")
                        .font(.rpCaption).foregroundStyle(Theme.inkDim)
                }
                Text("You already made \(parkedClipCount) AI clip\(parkedClipCount == 1 ? "" : "s") for this \(space.spaceNoun) and they're saved on this phone. Putting them together into a reel happens right here and costs nothing.")
                    .font(.rpCaption).foregroundStyle(Theme.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
                Button { finishParkedReel() } label: {
                    Label("Finish that reel", systemImage: "film.stack")
                        .font(.rpBody.weight(.semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(Theme.accent).foregroundStyle(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(ScalePressStyle())
                .accessibilityLabel(Text("Finish that reel from the clips you already paid for"))
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
                Text("YOUR LAST REEL").font(.rpKicker).foregroundStyle(Theme.inkDim)
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
                Text("Making a new reel generates fresh AI clips. Your last few reels stay on this phone.")
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
                            Text("Opens the reel · AI-generated").font(.rpCaption).foregroundStyle(Theme.inkDim)
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
        if canGenerate { return "Make my reel" }
        if !selectedExtras.isEmpty { return "Pick 1 more photo" }
        return "Pick 2 photos first"
    }

    private var costText: String {
        // No per-unit dollar figures in UI while IAP is off (App Store 3.1.1).
        guard !selected.isEmpty else { return "Every photo you pick becomes 5 seconds of video." }
        return "\(selected.count) photo\(selected.count == 1 ? "" : "s") picked — that's \(selected.count * 5) seconds of video."
    }

    private var generatingSection: some View {
        VStack(spacing: 14) {
            ProgressView(value: Double(completedClips), total: Double(max(totalClips, 1)))
                .tint(Theme.accent)
            Text(statusText)
                .font(.rpHeadline)
                .foregroundStyle(Theme.ink)
            Text("Each photo takes about a minute. Keep this screen open — your reel is put together as soon as they're done.")
                .font(.rpCaption)
                .foregroundStyle(Theme.inkDim)
                .multilineTextAlignment(.center)
            if failedClips > 0 {
                Text("\(failedClips) clip\(failedClips == 1 ? "" : "s") failed — continuing with the rest.")
                    .font(.rpCaption)
                    .foregroundStyle(Theme.warn)
            }
            Button("Cancel", role: .destructive) { cancelWork() }
                .font(.rpBody)
                .padding(.top, 6)
            // Say the money part out loud. Cancelling used to delete every clip
            // already generated and charged for, silently (the 4,000 sq ft field
            // test); now it keeps them and this line promises so before the tap.
            Text("Cancelling keeps the clips you've already paid for — you can finish the reel from them later.")
                .font(.rpCaption)
                .foregroundStyle(Theme.inkDim)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var stitchingSection: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(1.3)
                .padding(.top, 16)
            Text("Putting your reel together…")
                .font(.rpHeadline)
                .foregroundStyle(Theme.ink)
            Text("Joining everything into one \(portrait ? "tall" : "wide") video, here on your phone.")
                .font(.rpCaption)
                .foregroundStyle(Theme.inkDim)
                .multilineTextAlignment(.center)
            if failedClips > 0 {
                Text("\(failedClips) clip\(failedClips == 1 ? "" : "s") failed — the reel uses the rest.")
                    .font(.rpCaption)
                    .foregroundStyle(Theme.warn)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    @ViewBuilder private var doneSection: some View {
        VStack(spacing: 12) {
            Label("Your reel is ready", systemImage: "checkmark.circle.fill")
                .font(.rpHeadline)
                .foregroundStyle(Theme.good)
            if failedClips > 0 {
                Text("\(failedClips) clip\(failedClips == 1 ? "" : "s") failed — the reel uses the rest.")
                    .font(.rpCaption)
                    .foregroundStyle(Theme.warn)
            }
            if let player {
                VideoPlayer(player: player)
                    .frame(height: portrait ? 460 : 230)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                    .onAppear { player.play() }
            }
            if let reelURL {
                Button { saveToPhotos(reelURL) } label: {
                    Label(savedToPhotos ? "Saved to Photos" : "Save to Photos",
                          systemImage: savedToPhotos ? "checkmark.circle.fill" : "square.and.arrow.down")
                        .font(.rpBody.weight(.semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(Theme.accent).foregroundStyle(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .disabled(savedToPhotos || isSaving)

                ShareLink(item: reelURL) {
                    Label("Share reel", systemImage: "square.and.arrow.up")
                        .font(.rpBody.weight(.semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 13)
                        .background(Theme.accentSoft).foregroundStyle(Theme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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

    private var failedSection: some View {
        VStack(spacing: 12) {
            if let failure {
                AIFailureCard(failure: failure,
                              retryHint: "Check your photos and try again.",
                              quotaFeature: "reels",
                              onSignIn: { showSignIn = true })
            } else {
                Label("Couldn't make the reel", systemImage: "exclamationmark.triangle")
                    .font(.rpHeadline)
                    .foregroundStyle(Theme.warn)
            }
            Button("Try again") { resetToSetup() }
                .font(.rpBody.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
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
            stepTitle(2, "ADD YOUR VOICE", "Optional. Talk over your reel and the words appear as captions.")
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
        case .off:     return "No talking. The reel plays with no sound."
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
        .disabled(isTranscribing)
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

    // --- AI voice: script + voice → ElevenLabs (spends money; sign-in gated) ---

    // Every body here stays tiny on purpose — see the note above
    // `stepVoiceCard`. `aiVoicePane` is a list of identifiers and nothing else.
    @ViewBuilder private var aiVoicePane: some View {
        VStack(alignment: .leading, spacing: 10) {
            scriptAssistRow
            scriptField
            scriptLengthRow
            scriptLengthNote
            aiVoicePicker
            makeVoiceButton
        }
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
                        Text("✨ Write my script")
                    }
                }
                .font(.rpBody.weight(.semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 13)
                .background(Theme.accentSoft).foregroundStyle(Theme.accent)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .disabled(scriptInFlight || ttsInFlight)
            .accessibilityIdentifier("reel.script.write")
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Uses this \(space.spaceNoun)'s own details. Every word stays editable.")
                    .font(.rpCaption).foregroundStyle(Theme.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                toneMenu
            }
        }
    }

    /// Tone lives HERE — one small menu beside the explanation line, not a step
    /// of its own and not a question anybody has to answer. The default already
    /// suits the space type.
    private var toneMenu: some View {
        Picker("Tone", selection: $tone) {
            ForEach(ScriptTone.allCases, id: \.self) { t in
                Text(t.label).tag(t)
            }
        }
        .pickerStyle(.menu)
        .tint(Theme.accent)
        .font(.rpCaption)
        .disabled(scriptInFlight)
        .accessibilityLabel(Text("How the script should sound"))
    }

    private var scriptField: some View {
        TextField("Type what the voice should say — e.g. 'Welcome to 12 Oak Lane. Three beds, two baths.'",
                  text: $aiScript, axis: .vertical)
            .lineLimit(2...5)
            .textFieldStyle(.roundedBorder)
            .disabled(ttsInFlight || scriptInFlight)
            .accessibilityIdentifier("reel.script.field")
    }

    /// Live length, in BOTH units that matter: characters against the server's
    /// hard 1,000-char cap, and seconds against the reel this script has to fit.
    ///
    /// Neither was visible before. The cap announced itself as a 400 only after
    /// somebody had written a paragraph, and the overrun announced itself as a
    /// finished video that freezes on its last picture — because `stitch()`
    /// HOLDS the final frame rather than cutting the speaker off. Both are now
    /// on screen before a cent is spent. Same shape as the 600-char counter in
    /// `CustomEditSheet`.
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
            Text("This takes about \(Self.wholeSeconds(scriptReadSeconds)) seconds to read and your reel is \(reelSeconds) seconds long. The video will freeze on its last picture while the voice finishes — add photos, or cut a sentence.")
                .font(.rpCaption).foregroundStyle(Theme.warn)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var makeVoiceButton: some View {
        Button { generateAIVoice() } label: {
            Label(ttsInFlight ? "Making the voice…" : "Make the voice", systemImage: "waveform")
                .font(.rpBody.weight(.semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 16)
                .background(aiCanGenerate ? Theme.accent : Theme.fillSubtle)
                .foregroundStyle(aiCanGenerate ? Color.white : Theme.inkDim)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .disabled(!aiCanGenerate)
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
            Picker("Voice", selection: $selectedVoiceID) {
                ForEach(aiVoices) { v in
                    Text(voiceRowLabel(v)).tag(v.voiceID)
                }
            }
            .pickerStyle(.menu)
            .tint(Theme.accent)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func voiceRowLabel(_ v: AIVoice) -> String {
        v.subtitle.isEmpty ? v.displayName : "\(v.displayName) · \(v.subtitle)"
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
    private var reelSeconds: Int { 5 * totalSelected }

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
        return "About \(wholeSeconds(readSeconds))s to read · your reel is \(reelSeconds)s"
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
        voiceError = nil
        voiceNote = nil
        speechDenied = false
        Task {
            // `requestPermissions()` is mic AND speech; it prompts for both.
            let both = await recorder.requestPermissions()
            await MainActor.run {
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
    }

    /// The one line shown when the recording will have no captions because
    /// Speech Recognition is off. Same words wherever that happens.
    private static let captionsOffNote =
        "Captions are off — Speech Recognition is turned off in Settings."

    /// Clear the last take and start a new one. Main-actor only.
    private func beginTake() {
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
    /// Sign-in gated — the AI runs on the account.
    private func loadVoices() {
        guard signedIn else { showSignIn = true; return }
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
        guard signedIn else { showSignIn = true; return }
        guard !scriptInFlight else { return }
        guard aiScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showScriptReplaceConfirm = true
            return
        }
        runScriptWriter()
    }

    /// The call itself. Sign-in gated (the AI runs on the account); one call per
    /// tap; the result lands in the EDITABLE field, never in a modal — the whole
    /// point is that the agent fixes the two words the model got wrong.
    private func runScriptWriter() {
        guard signedIn else { showSignIn = true; return }
        guard !scriptInFlight else { return }
        scriptInFlight = true
        voiceError = nil
        voiceNote = nil
        Haptics.selection()

        // Everything the request needs is read HERE, on the main actor, into
        // plain Sendable values. The Task below never reaches back into the
        // model or the view for anything.
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
                var req = request
                // Only ever an UPGRADE on what `scriptRequest` already read off
                // the listing: a nil answer here (offline, signed out, listing
                // gone) must not throw away an id we already knew.
                if !isSample, let resolved = await model.serverListingIDForCompliance(listingID) {
                    req.listingServerID = resolved
                }
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
    /// Spends money, so: sign-in gated, one call per tap (`ttsInFlight`), one
    /// idempotency key per tap, NEVER auto-retried — a fair-housing refusal (400)
    /// would fail identically, so the server's message is shown to re-word.
    private func generateAIVoice() {
        guard signedIn else { showSignIn = true; return }
        guard !ttsInFlight else { return }
        let script = aiScript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard script.count >= 2 else { voiceError = "Type a short script first."; return }
        let voiceID = selectedVoiceID
        guard !voiceID.isEmpty else { voiceError = "Pick a voice first."; return }
        let api = model.api                       // snapshot on the main actor
        let listingID = listing.id
        let isSample = listing.isSample
        let key = UUID().uuidString               // one idempotency key per tap
        ttsInFlight = true
        voiceError = nil
        voiceNote = nil
        Task {
            do {
                let serverID: UUID? = isSample ? nil
                    : await model.serverListingIDForCompliance(listingID)
                let result = try await api.aiVoiceTTS(text: script, voiceID: voiceID,
                                                      listingServerID: serverID,
                                                      label: "Reel voiceover",
                                                      idempotencyKey: key)
                let persisted = try await Self.downloadVoiceover(from: result.audioURL,
                                                                 listingID: listingID.uuidString)
                let vo = Voiceover(audioURL: persisted, duration: result.durationS,
                                   transcript: script, words: result.words,
                                   source: .aiVoice, voiceName: result.voiceName)
                await MainActor.run {
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
                    voiceError = message
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

    private func selectThumb(_ p: EnhancedPhoto) -> some View {
        let order = selected.firstIndex(of: p.id)
        return Button { toggle(p) } label: {
            ZStack(alignment: .topTrailing) {
                DetailPhotoThumb(url: p.enhancedURL, height: 100)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(order != nil ? Theme.accent : Theme.border,
                                          lineWidth: order != nil ? 2 : 1)
                    )
                    .opacity(order == nil && selected.count >= 8 ? 0.4 : 1)

                if let order {
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
        .accessibilityLabel(Text(order.map { "Photo in reel — position \($0 + 1). Tap to remove." }
                                 ?? "Photo not in reel. Tap to add."))
    }

    private func toggle(_ p: EnhancedPhoto) {
        if let idx = selected.firstIndex(of: p.id) {
            selected.remove(at: idx)
        } else if selected.count < 8 {
            selected.append(p.id)
            Haptics.selection()
        }
    }

    private func cancelWork() {
        let task = workTask
        workTask = nil
        task?.cancel()
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
        player?.pause()
        player = nil
        reelURL = nil
        savedToPhotos = false
        saveError = nil
        failure = nil
        completedClips = 0
        totalClips = 0
        failedClips = 0
        phase = .setup
        lastReel = Self.newestReel(for: listing.id)   // the one just made is now "your last reel"
        // A run that failed part-way parked its billed clips — surface them again
        // rather than letting "Try again" charge for the same clips twice.
        parkedClips = listing.isSample ? nil : PendingReelClips.load(for: listing.id)
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
        reelURL = url
        player = AVPlayer(url: url)
        savedToPhotos = false
        saveError = nil
        failure = nil
        failedClips = 0
        phase = .done
        Haptics.selection()
        Task {
            guard let isPortrait = await Self.isPortraitVideo(url) else { return }
            await MainActor.run { portrait = isPortrait }
        }
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
        for url in files.dropFirst(keeping) {
            try? FileManager.default.removeItem(at: url)
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

    // MARK: Generate (sequential clips → on-device stitch)

    private func generate() {
        guard signedIn, phase == .setup, canGenerate else { return }
        if recorder.isRecording { recorder.cancel() }   // never leave the mic hot
        let chosen = selected.compactMap { id in photos.first(where: { $0.id == id }) }
        let extras = selectedExtras.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard chosen.count + extras.count >= 2 else { return }
        let api = model.api                       // snapshot on the main actor
        let isPortrait = portrait
        let prompt = motionPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let listingID = listing.id
        // Caption text is resolved HERE (main actor, plain Sendable strings) —
        // the CALayers themselves are built inside the nonisolated stitch.
        let captions: ReelCaptions? = captionsOn ? Self.reelCaptions(for: listing) : nil
        // Voiceover + caption-style snapshot on the main actor (both Sendable).
        // `.off` mode → no voiceover; a finished take is used only when the mode
        // isn't .off. captionStyle governs the burned-in spoken-word captions.
        let voiceover: Voiceover? = (voiceMode == .off) ? nil : self.voiceover
        let captionStyle: CaptionStyle = wordCaptionsOn ? .standard : .off
        // The big burned-in shot captions and the transition, snapshot as plain
        // Sendable values like everything else this Task reads.
        let shotStyle: ReelComposer.ShotCaptionStyle = bigCaptionsOn ? bigCaptionStyle : .off
        let transition = reelTransition
        // What the shot planner needs, read here on the main actor. The call
        // itself happens inside the Task and is allowed to fail.
        let live = model.listings.first(where: { $0.id == listing.id }) ?? listing
        let planRequest = Self.shotlistRequest(for: live, space: space,
                                               photos: chosen,
                                               targetSeconds: targetSeconds,
                                               tone: tone.rawValue)
        let address = live.address
        let noun = space.spaceNoun
        let spaceRaw = space.rawValue
        phase = .generating
        completedClips = 0
        totalClips = chosen.count
        failedClips = 0
        failure = nil
        statusText = chosen.isEmpty ? "Getting ready…" : "Planning your shots…"
        Haptics.selection()
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reel-\(UUID().uuidString)", isDirectory: true)
        let isSample = listing.isSample
        workTask = Task {
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
                // THE SHOT PLAN. One text-only `/ai-copy/shotlist` call, before a
                // cent is spent on video: a camera move, a three-to-five-word
                // caption and a length for each photo. It is a BEST EFFORT and
                // nothing below depends on it — `planShots` never throws, and an
                // empty plan puts every downstream decision back exactly where it
                // was before this route existed (nil motion, whole clips, no shot
                // captions). It runs first because the motion has to be known
                // before the clip is submitted, not after.
                var plan: [AIShot] = []
                if !chosen.isEmpty {
                    var req = planRequest
                    if let resolved = reelListingServerID { req.listingServerID = resolved }
                    plan = await Self.planShots(req, api: api, address: address, fallbackNoun: noun)
                    let planned = plan.isEmpty ? "false" : "true"
                    let shotCount = String(plan.count)
                    await MainActor.run {
                        Analytics.track("reel_planned", ["ok": planned,
                                                         "space_type": spaceRaw,
                                                         "shots": shotCount])
                    }
                }
                // The plan may REORDER the reel — it opens on the best
                // establishing shot and closes on the best closing frame, with
                // the agent's tap order as its tiebreak. `reordered` is all or
                // nothing: anything it cannot account for photo-for-photo leaves
                // the tap order exactly as it was.
                let ordered = Self.reordered(chosen, by: plan)
                try Task.checkCancellation()

                var clipURLs: [URL] = extras          // ready-made clips lead the reel
                // The plan entries that actually produced a clip, in clip order.
                // Kept in step with `clipURLs` so a failed clip cannot slide every
                // later caption onto the wrong picture.
                var usedShots: [AIShot?] = []
                for (i, photo) in ordered.enumerated() {
                    try Task.checkCancellation()
                    await MainActor.run { statusText = "Photo \(i + 1) of \(ordered.count) — making video…" }
                    let shot = Self.shot(for: photo, in: plan)
                    do {
                        let clip = try await Self.makeClip(photo: photo, prompt: prompt,
                                                           shot: shot, shotCount: ordered.count,
                                                           api: api, listingServerID: reelListingServerID,
                                                           into: tmpDir, index: i)
                        clipURLs.append(clip)
                        usedShots.append(shot)
                        billedClips.append(clip)   // paid for the moment it lands
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch let apiError as APIError where apiError.isQuota || apiError.isUnauthorized {
                        // A plan boundary or expired session won't fix itself on
                        // the next clip — stop and say so.
                        throw apiError
                    } catch {
                        // One bad clip never kills the reel — note it and move on.
                        await MainActor.run { failedClips += 1 }
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
                let stamp = Int(Date().timeIntervalSince1970)
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
                try? FileManager.default.removeItem(at: tmpDir)

                try Task.checkCancellation()
                let wasPlanned = usedShots.contains(where: { $0 != nil }) ? "true" : "false"
                await MainActor.run {
                    reelURL = outURL
                    player = AVPlayer(url: outURL)
                    lastReel = outURL
                    phase = .done
                    Haptics.success()
                    Analytics.track("reel_made", ["ok": "true", "clips": String(clipURLs.count),
                                                  "captions": shotStyle.rawValue,
                                                  "transition": transition.rawValue,
                                                  "planned": wasPlanned])
                }
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
                    parkedClips = PendingReelClips.load(for: listingID)
                    phase = .failed
                    failure = AIFailure(error, title: "Couldn't make the reel")
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
        defer { try? fm.removeItem(at: tmpDir) }
        guard !clips.isEmpty else { return }
        let dir = PendingReelClips.directory(for: listingID)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return   // nowhere to put them; the defer still clears tmp
        }
        // Start from what is already parked, dropping any entry whose file has
        // since gone so the record can't accumulate dead paths.
        var relPaths = (PendingReelClips.load(for: listingID)?.clipURLs ?? [])
            .map { FileStore.relativePath(for: $0) }
        let stamp = Int(Date().timeIntervalSince1970)
        for (i, clip) in clips.enumerated() {
            guard fm.fileExists(atPath: clip.path) else { continue }
            let dest = dir.appendingPathComponent("clip-\(stamp)-\(i).mp4")
            try? fm.removeItem(at: dest)
            do {
                try fm.moveItem(at: clip, to: dest)
            } catch {
                // tmp and Documents are the same volume so a move should not
                // fail — but a copy is the difference between keeping the agent's
                // money and losing it, so try that before giving up on this clip.
                do { try fm.copyItem(at: clip, to: dest) } catch { continue }
            }
            relPaths.append(FileStore.relativePath(for: dest))
        }
        guard !relPaths.isEmpty else { return }
        PendingReelClips(listingID: listingID, savedAt: Date(), relPaths: relPaths).save()
    }

    /// Stitch the parked clips into a reel. NO AI call, no network, no spend —
    /// the clips were bought on an earlier run; this is the free half of the job
    /// the old cancel path threw away.
    ///
    /// Any aerial/extra clip still switched on leads the reel, exactly as it does
    /// in `generate()`. Shape, title card and voiceover come from whatever the
    /// setup screen currently says, because those are free to change and the
    /// clips are not.
    private func finishParkedReel() {
        guard !isWorking else { return }
        let clips = (selectedExtras.filter { FileManager.default.fileExists(atPath: $0.path) })
            + (parkedClips?.clipURLs ?? [])
        guard !clips.isEmpty else {
            PendingReelClips.clear(for: listing.id)
            parkedClips = nil
            return
        }
        if recorder.isRecording { recorder.cancel() }   // never leave the mic hot
        let listingID = listing.id
        let isPortrait = portrait
        let captions: ReelCaptions? = captionsOn ? Self.reelCaptions(for: listing) : nil
        let voiceover: Voiceover? = (voiceMode == .off) ? nil : self.voiceover
        let captionStyle: CaptionStyle = wordCaptionsOn ? .standard : .off
        failure = nil
        failedClips = 0
        phase = .stitching
        Haptics.selection()
        workTask = Task {
            do {
                let renderSize = isPortrait ? CGSize(width: 1080, height: 1920)
                                            : CGSize(width: 1920, height: 1080)
                let reelsDir = FileStore.documents.appendingPathComponent("reels", isDirectory: true)
                try FileManager.default.createDirectory(at: reelsDir, withIntermediateDirectories: true)
                let stamp = Int(Date().timeIntervalSince1970)
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
                                                  captionStyle: captionStyle),
                    output: outURL)
                try Task.checkCancellation()
                await MainActor.run {
                    // The clips now live inside a finished reel on disk, so the
                    // parked copy has done its job and can go. This is the ONLY
                    // automatic delete of paid clips in the whole flow.
                    PendingReelClips.clear(for: listingID)
                    parkedClips = nil
                    reelURL = outURL
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
        PendingReelClips.clear(for: listing.id)
        parkedClips = nil
        Haptics.selection()
    }

    /// One photo → 5 s AI motion clip: downscale ≤1280 → jpeg b64 → submit
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
                                             api: APIClient, listingServerID: UUID?,
                                             into dir: URL, index: Int) async throws -> URL {
        guard let ui = UIImage(contentsOfFile: photo.enhancedURL.path) else {
            throw AIImagePrep.error("Couldn't read that photo.")
        }
        let scaled = AIImagePrep.downscaled(ui, maxDimension: 1280)
        guard let jpeg = scaled.jpegData(compressionQuality: 0.85) else {
            throw AIImagePrep.error("Couldn't prepare that photo.")
        }
        // No motion text → send NOTHING and let `/ai-video/reel-clip` use its own
        // space-aware anti-hallucination prompt (F-A-24). Sending a canned client
        // sentence took the caller-supplied branch instead, which both skipped
        // the server's stronger default and wrote our own words into the
        // listing's provenance log as if the agent had typed them.
        let typed: String? = prompt.isEmpty ? nil : prompt
        let job = try await api.aiVideoReelClip(imageBase64: jpeg.base64EncodedString(),
                                                mime: "image/jpeg", prompt: typed, seconds: 5,
                                                motion: shot?.motion, room: shot?.room,
                                                shotIndex: index, shotCount: shotCount,
                                                listingServerID: listingServerID,
                                                label: Self.clipLabel(shot: shot, index: index),
                                                idempotencyKey: UUID().uuidString)

        let deadline = Date().addingTimeInterval(5 * 60)
        var remoteURL: URL?
        while remoteURL == nil {
            guard Date() < deadline else {
                throw AIImagePrep.error("The clip took too long.")
            }
            try await Task.sleep(nanoseconds: 5_000_000_000)
            switch try await api.aiVideoStatus(job) {
            case .processing:
                break   // keep polling — the caller shows "Clip X of N"
            case .completed(let videoURL):
                remoteURL = videoURL
            case .failed(let message):
                throw AIImagePrep.error(message)
            }
        }
        guard let remoteURL else {
            throw AIImagePrep.error("The AI didn't return a clip.")
        }

        let (tmp, resp) = try await URLSession.shared.download(from: remoteURL)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AIImagePrep.error("Couldn't download the finished clip (HTTP \(http.statusCode)).")
        }
        let dest = dir.appendingPathComponent("clip-\(index).mp4")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
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

/// Multi-select Photos picker (images only). `selectionLimit: 1` for a single
/// exterior photo; the studio's default of 15 for batch ingest.
struct LibraryImagePicker: UIViewControllerRepresentable {
    var selectionLimit: Int = 15
    let onPicked: ([UIImage]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = selectionLimit
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPicked: onPicked) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPicked: ([UIImage]) -> Void
        init(onPicked: @escaping ([UIImage]) -> Void) { self.onPicked = onPicked }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            let group = DispatchGroup()
            let lock = NSLock()
            var images: [UIImage] = []
            for result in results where result.itemProvider.canLoadObject(ofClass: UIImage.self) {
                group.enter()
                result.itemProvider.loadObject(ofClass: UIImage.self) { obj, _ in
                    if let img = obj as? UIImage {
                        lock.lock(); images.append(img); lock.unlock()
                    }
                    group.leave()
                }
            }
            group.notify(queue: .main) { self.onPicked(images) }
        }
    }
}

/// Single-shot camera capture.
struct CameraPicker: UIViewControllerRepresentable {
    let onPicked: (UIImage) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPicked: onPicked) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onPicked: (UIImage) -> Void
        init(onPicked: @escaping (UIImage) -> Void) { self.onPicked = onPicked }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            picker.dismiss(animated: true)
            if let img = info[.originalImage] as? UIImage { onPicked(img) }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}

// MARK: - Floor plan (Apple RoomPlan → USDZ "dollhouse")
// LiDAR-only (iPhone/iPad Pro). Scans room after room in ONE AR session, merges
// them with RoomPlan's StructureBuilder (iOS 17+, and it handles rooms on
// different storeys), exports USDZ, and previews it with QuickLook.
// Per-listing file in Documents/FloorPlans/.

struct FloorPlanView: View {
    let listing: Listing

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
                    .background(Theme.accentSoft).foregroundStyle(Theme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                if RoomCaptureSession.isSupported {
                    VStack(spacing: 10) {
                        Image(systemName: planExists ? "cube.fill" : "cube.transparent")
                            .font(.system(size: 44, weight: .light))
                            .foregroundStyle(Theme.accent)
                        Text(planExists ? "Floor plan ready" : "Scan the floor plan")
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
                        secondaryButton("Scan again", "arrow.clockwise") { showRescanConfirm = true }
                        ShareLink(item: usdzURL) {
                            Label("Share the 3D model", systemImage: "square.and.arrow.up")
                                .font(.rpBody.weight(.semibold))
                                .frame(maxWidth: .infinity).padding(.vertical, 13)
                                .background(Theme.accentSoft).foregroundStyle(Theme.accent)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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

                    Divider().padding(.vertical, 6)
                    Text("Already have blueprints or measurements?")
                        .font(.rpKicker).foregroundStyle(Theme.inkDim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    uploadSection
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: uploadedURL != nil ? "doc.richtext" : "square.and.arrow.up.on.square")
                            .font(.system(size: 40, weight: .light))
                            .foregroundStyle(Theme.accent)
                        Text(uploadedURL != nil ? "Floor plan ready" : "Add a floor plan")
                            .font(.rpTitle)
                            .foregroundStyle(Theme.ink)
                        Text("This device has no LiDAR for 3D scanning — but you can upload a PDF or image of your floor plan or blueprints. Your photos and video tour work on every device.")
                            .font(.rpBody).foregroundStyle(Theme.inkDim)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                    uploadSection
                }
            }
            .padding()
        }
        .background(Theme.bg)
        .navigationTitle("Floor plan")
        .navigationBarTitleDisplayMode(.inline)
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

    private func primaryButton(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.rpBody.weight(.semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(Theme.accent).foregroundStyle(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                                .background(Theme.accentSoft).foregroundStyle(Theme.accent)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                Text("Approximate — measured by phone scan, not a survey.")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.inkDim)
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
private struct PlanExportSheet: View {
    let image: UIImage
    let address: String
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

                    Text("Dimensions and area are approximate — a phone scan is not a survey.")
                        .font(.rpCaption)
                        .foregroundStyle(Theme.inkDim)
                        .multilineTextAlignment(.center)

                    Button { save() } label: {
                        Label(saved ? "Saved to Photos" : "Save to Photos",
                              systemImage: saved ? "checkmark.circle.fill" : "square.and.arrow.down")
                            .font(.rpBody.weight(.semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(Theme.accent).foregroundStyle(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .disabled(saved || isSaving)

                    ShareLink(item: Image(uiImage: image),
                              preview: SharePreview(address.isEmpty ? "Room plan" : "Room plan — \(address)",
                                                    image: Image(uiImage: image))) {
                        Label("Share image", systemImage: "square.and.arrow.up")
                            .font(.rpBody.weight(.semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 13)
                            .background(Theme.accentSoft).foregroundStyle(Theme.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
        isSaving = true
        saveError = nil
        let img = image
        Task {
            do {
                try await PhotosLibrarySaver.saveImage(img)
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
        // Summed PER ROOM, never as one hull over the whole storey: the convex hull
        // of a single room's wall endpoints is close to its true footprint, but one
        // hull thrown around an entire L-shaped floor bridges straight across the
        // notch and invents square footage that does not exist.
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
            ctx.draw(Text("\(scope) ≈ \(Int(areaSqFt.rounded())) sq ft")
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
