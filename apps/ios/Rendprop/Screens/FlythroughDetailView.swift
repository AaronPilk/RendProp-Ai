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
    @State private var showQR = false
    @State private var showSignIn = false
    @State private var isPublishing = false
    @State private var publishFailure: AIFailure?
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
                toolboxSection
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
        }
        .onChange(of: spaceTypeRaw) { _ in
            // The list this screen was opened from no longer contains this
            // listing — go back rather than showing another industry's detail.
            if !currentListing.belongsToCurrentType { dismiss() }
        }
        .sheet(isPresented: $showRoomTagger, onDismiss: roomTaggerDismissed) {
            if let a = asset {
                RoomTaggerView(videoURL: a.localURL, tags: roomTagsBinding)
            }
        }
        .sheet(isPresented: $showAerialIntro) {
            AerialIntroSheet(listing: currentListing)
                .environmentObject(model)
        }
        .sheet(isPresented: $showEdit) {
            ListingEditSheet(listing: currentListing)
                .environmentObject(model)
        }
        .sheet(isPresented: $showQR) {
            if let shareURL {
                QRShareSheet(url: shareURL, title: currentListing.address)
            }
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
            PlayerWebView(localVideoURL: playbackURL, roomTags: playbackTags, listing: currentListing)
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
    private func shareSection(_ url: URL) -> some View {
        VStack(spacing: 10) {
            ShareLink(item: url,
                      subject: Text(currentListing.address),
                      message: Text("Fly through \(currentListing.address) — scroll to walk the \(space.spaceNoun).")) {
                HStack {
                    Image(systemName: "square.and.arrow.up")
                    Text("Share flythrough").fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Theme.accent)
                .foregroundStyle(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            HStack(spacing: 10) {
                Button {
                    UIPasteboard.general.url = url
                    Haptics.success()
                } label: {
                    Label("Copy link", systemImage: "link")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                Button { showQR = true } label: {
                    Label("QR code", systemImage: "qrcode")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .font(.rpBody)

            if let chapterSyncNote {
                Text(chapterSyncNote)
                    .font(.rpCaption)
                    .foregroundStyle(Theme.inkDim)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
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
        let aerialSub = currentListing.aerialURL != nil ? "Aerial ready" : "AI opening shot"
        return VStack(alignment: .leading, spacing: 10) {
            Text("TOOLBOX").font(.rpKicker).foregroundStyle(Theme.inkDim)
                .frame(maxWidth: .infinity, alignment: .leading)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                GridItem(.flexible(), spacing: 10)], spacing: 10) {
                NavigationLink { PhotoStudioView(listing: currentListing) } label: {
                    toolCard("Photos & AI edits", sample ? createFirst : "Twilight · staging · declutter",
                             "wand.and.stars", RPGradient.photo, ai: true, dimmed: sample)
                }
                .buttonStyle(ScalePressStyle())
                .disabled(sample)

                NavigationLink { PhotoStudioView(listing: currentListing, intent: .reel) } label: {
                    toolCard("Make a reel", sample ? createFirst : "Photos → social video",
                             "film.stack", RPGradient.reel, ai: true, dimmed: sample)
                }
                .buttonStyle(ScalePressStyle())
                .disabled(sample)

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
        currentListing.serverShareURL != nil
            ? "Removes the video, photos and tour from this phone and takes the share link offline. This can't be undone."
            : "Removes the video, photos and tour from this phone. This can't be undone."
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
                Text("Leads appear here; email alerts coming.")
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

    private func mapsURL(_ c: CLLocationCoordinate2D) -> URL? {
        var comps = URLComponents(string: "https://maps.apple.com/")
        comps?.queryItems = [
            URLQueryItem(name: "ll", value: "\(c.latitude),\(c.longitude)"),
            URLQueryItem(name: "q", value: currentListing.address),
        ]
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
                }
            } catch {
                await MainActor.run {
                    isPublishing = false
                    publishFailure = AIFailure(error, title: "Couldn't publish")
                }
            }
        }
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
    private func roomTaggerDismissed() {
        playerRefresh = UUID()
        let l = currentListing
        guard !l.isSample, let renderID = l.publishedRenderID, tour != nil else { return }
        let tags = model.assets[listing.id]?.roomTags ?? []
        guard tags != tagsBeforeEdit else { return }
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
                guard let region = Self.regionLabel(from: marks?.first) else { return }
                DispatchQueue.main.async { model.setRegion(region, for: id) }
            }
            return
        }
        geocoder.geocodeAddressString(addr) { marks, _ in
            guard let mark = marks?.first else { return }
            let coord = mark.location?.coordinate
            let region = Self.regionLabel(from: mark)
            DispatchQueue.main.async {
                if let c = coord, c.latitude.isFinite, c.longitude.isFinite {
                    model.setCoordinate(lat: c.latitude, lon: c.longitude, for: id)
                }
                if let region { model.setRegion(region, for: id) }
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

    static var pricingURL: URL? { Config.pricingURL ?? URL(string: "https://rendprop.com/pricing") }

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
                if let url = AIFailure.pricingURL {
                    Link(destination: url) {
                        Label("Upgrade plan", systemImage: "arrow.up.circle")
                            .font(.rpBody.weight(.semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(Theme.accent).foregroundStyle(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
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
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(Theme.fillSubtle)
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
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
                    Text("Scan to open the tour — print it on a flyer, sign-in sheet or yard sign.")
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
                                  preview: SharePreview("QR code — \(title)", image: Image(uiImage: image))) {
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
            .navigationTitle("QR code")
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

// MARK: - Photo studio (phone photos → pro listing images)
// Deterministic, on-device, zero-cost enhancement (shadow lift, vibrance,
// contrast, sharpen) plus AI edits through `/ai-photo`. Files live per-listing
// in Documents/Photos/<listingID>/ (enh-<id>.jpg + orig-<id>.jpg pairs).

struct EnhancedPhoto: Identifiable, Hashable {
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
    static func loadAll(listingID: UUID) -> [EnhancedPhoto] {
        let fm = FileManager.default
        let dir = directory(for: listingID)
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? []
        func created(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
        }
        return files
            .filter { $0.lastPathComponent.hasPrefix("enh-") }
            .map { e -> EnhancedPhoto in
                let id = e.deletingPathExtension().lastPathComponent
                    .replacingOccurrences(of: "enh-", with: "")
                let orig = dir.appendingPathComponent("orig-\(id).jpg")
                let origURL = fm.fileExists(atPath: orig.path) ? orig : e
                return EnhancedPhoto(id: id, originalURL: origURL, enhancedURL: e)
            }
            .sorted { a, b in
                let da = created(a.enhancedURL), db = created(b.enhancedURL)
                return da != db ? da > db : a.id > b.id
            }
    }
}

struct PhotoStudioView: View {
    /// Why the studio was opened — `.reel` adds a hint that the reel needs ≥2 photos.
    enum Intent { case photos, reel }

    @EnvironmentObject var model: AppModel
    @ObservedObject private var auth = AuthStore.shared
    let listing: Listing
    var intent: Intent = .photos

    private var mainRelPath: String? {
        model.listings.first(where: { $0.id == listing.id })?.mainPhotoRelPath
    }
    private func isMain(_ p: EnhancedPhoto) -> Bool {
        mainRelPath == FileStore.relativePath(for: p.enhancedURL)
    }
    private func setMain(_ p: EnhancedPhoto) {
        model.setMainPhoto(FileStore.relativePath(for: p.enhancedURL), for: listing.id)
        Haptics.success()
    }

    /// The business type the copy speaks in (samples follow the current type).
    private var space: SpaceType { listing.isSample ? SpaceType.current : listing.spaceType }
    private var stagingLabel: String { space == .realEstate ? "Virtual staging" : "Furnish & style" }

    @State private var photos: [EnhancedPhoto] = []
    @State private var showLibrary = false
    @State private var showCamera = false
    @State private var isProcessing = false
    @State private var processingText = "Enhancing…"
    @State private var compare: EnhancedPhoto?
    @State private var aiFailure: AIFailure?
    @State private var animatedClip: AnimatedClip?   // finished photo→reel clip
    @State private var customEditPhoto: EnhancedPhoto?   // photo awaiting a custom-prompt AI edit
    @State private var showReelStudio = false            // multi-photo → stitched social reel
    @State private var animateTask: Task<Void, Never>?   // photo→clip poll; cancelled when the studio is left
    @State private var wandPhoto: EnhancedPhoto?         // photo under the visible wand button
    @State private var showWandDialog = false            // wand → AI enhance chooser
    @State private var stagePhoto: EnhancedPhoto?        // photo awaiting a staging style
    @State private var showStageDialog = false           // staging style chooser
    @State private var suggestResult: SuggestResult?     // AI-suggested edits sheet payload
    @State private var showSignIn = false                // AI edits run on the user's account
    @Environment(\.openURL) private var openURL

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
            || showWandDialog || showStageDialog
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                HStack(spacing: 10) {
                    addButton("Add from Photos", "photo.stack", filled: true) { showLibrary = true }
                    addButton("Take a photo", "camera", filled: false) {
                        if UIImagePickerController.isSourceTypeAvailable(.camera) { showCamera = true }
                    }
                }

                // Reel Studio, front and center once there's enough to work with.
                if photos.count >= 2 {
                    reelBanner
                } else if intent == .reel {
                    Label("Add at least 2 photos — the Make a reel button appears right here.",
                          systemImage: "film.stack")
                        .font(.rpCaption)
                        .foregroundStyle(Theme.inkDim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

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
                    Text("Tap a photo to compare before & after · tap the wand for AI edits · long-press for more.")
                        .font(.rpCaption).foregroundStyle(Theme.inkDim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                photoGrid

                if !photos.isEmpty {
                    ShareLink(items: photos.map { $0.enhancedURL }) {
                        Label("Export all", systemImage: "square.and.arrow.up")
                            .font(.rpBody.weight(.semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(Theme.accent).foregroundStyle(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            }
            .padding()
        }
        .background(Theme.bg)
        .navigationTitle(space == .realEstate ? "Listing photos" : "\(space.spaceNounCap) photos")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadExisting)
        .onDisappear {
            if !isPresentingOverlay { animateTask?.cancel() }
        }
        .sheet(isPresented: $showLibrary) {
            LibraryImagePicker { imgs in ingest(imgs) }.ignoresSafeArea()
        }
        .sheet(isPresented: $showCamera) {
            CameraPicker { img in ingest([img]) }.ignoresSafeArea()
        }
        .sheet(isPresented: $showSignIn) { SignInView.forAI("AI photo edits") }
        .fullScreenCover(item: $compare) { p in PhotoCompareView(photo: p) }
        .sheet(item: $animatedClip) { clip in AnimatedClipSheet(clip: clip) }
        .sheet(item: $customEditPhoto) { p in
            CustomEditSheet(photo: p, api: model.api) { prompt in
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
            ReelStudioView(listing: listing, photos: photos)
                .environmentObject(model)
        }
        // The wand's visible menu — same edits as the long-press path, one tap.
        .confirmationDialog("AI enhance", isPresented: $showWandDialog,
                            titleVisibility: .visible, presenting: wandPhoto) { p in
            Button("✨ Suggest edits for this photo") { suggestEdits(p) }
            Button("Twilight sky") { aiEdit(p, "twilight") }
            Button("Blue sky") { aiEdit(p, "sky") }
            if space == .realEstate {
                Button("Green lawn") { aiEdit(p, "lawn") }
            }
            Button("Declutter") { aiEdit(p, "declutter") }
            Button("\(stagingLabel)…") {
                stagePhoto = p
                // Present after this dialog finishes dismissing.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { showStageDialog = true }
            }
            Button("Custom edit…") { openCustomEdit(p) }
            Button("Animate (5s clip)") { animate(p) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Each edit saves as a new photo — the original stays.")
        }
        .confirmationDialog("Staging style", isPresented: $showStageDialog,
                            titleVisibility: .visible, presenting: stagePhoto) { p in
            Button("Modern") { aiEdit(p, "stage", style: "modern") }
            Button("Rustic") { aiEdit(p, "stage", style: "rustic") }
            Button("Minimalist") { aiEdit(p, "stage", style: "minimalist") }
            Button("Scandinavian") { aiEdit(p, "stage", style: "scandinavian") }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(space == .realEstate
                 ? "AI furnishes the room in the style you pick."
                 : "AI furnishes the \(space.spaceNoun) in the style you pick — walls and windows stay as they are.")
        }
        .alert(aiFailure?.title ?? "That one didn't work",
               isPresented: Binding(get: { aiFailure != nil }, set: { if !$0 { aiFailure = nil } }),
               presenting: aiFailure) { f in
            if f.isQuota, let url = AIFailure.pricingURL {
                Button("Upgrade plan") { openURL(url) }
            }
            if f.isUnauthorized {
                Button("Sign in") { showSignIn = true }
            }
            Button("OK", role: .cancel) { aiFailure = nil }
        } message: { f in
            Text(f.fullMessage)
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
            Button { aiEdit(p, "twilight") } label: { Label("Twilight", systemImage: "moon.stars") }
            Button { aiEdit(p, "sky") } label: { Label("Blue sky", systemImage: "cloud.sun") }
            if space == .realEstate {
                Button { aiEdit(p, "lawn") } label: { Label("Green lawn", systemImage: "leaf") }
            }
            Button { aiEdit(p, "declutter") } label: { Label("Declutter", systemImage: "sparkles.rectangle.stack") }
            Menu {
                Button { aiEdit(p, "stage", style: "modern") } label: { Text("Modern") }
                Button { aiEdit(p, "stage", style: "rustic") } label: { Text("Rustic") }
                Button { aiEdit(p, "stage", style: "minimalist") } label: { Text("Minimalist") }
                Button { aiEdit(p, "stage", style: "scandinavian") } label: { Text("Scandinavian") }
            } label: {
                Label(stagingLabel, systemImage: "sofa")
            }
            Button { openCustomEdit(p) } label: { Label("Custom edit…", systemImage: "text.bubble") }
        } label: {
            Label("AI enhance", systemImage: "wand.and.stars")
        }
        Button { animate(p) } label: {
            Label("Animate (5s clip)", systemImage: "play.rectangle.on.rectangle")
        }
        Button { setMain(p) } label: {
            Label("Use as cover photo", systemImage: "star")
        }
        Button(role: .destructive) { delete(p) } label: {
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
    private func aiEdit(_ p: EnhancedPhoto, _ edit: String,
                        style: String? = nil, prompt: String? = nil) {
        guard !isProcessing else { return }
        guard requireSignIn() else { return }
        isProcessing = true
        processingText = "Enhancing…"
        let api = model.api          // snapshot on the main actor
        let targetDir = dir
        let source = p.enhancedURL
        let tapKey = UUID().uuidString   // one idempotency key per user tap
        Task {
            do {
                guard let b64 = await AIImagePrep.jpegBase64(at: source, maxDimension: 2048, quality: 0.9) else {
                    throw AIImagePrep.error("Couldn't read that photo.")
                }
                let outB64 = try await api.aiPhotoEdit(
                    imageBase64: b64, mime: "image/jpeg", edit: edit,
                    style: style, prompt: prompt, idempotencyKey: tapKey)
                // Save with the same enh-/orig- convention as ingested photos: a
                // UUID-named PNG was skipped by loadExisting (enh- filter) and lost
                // on relaunch. Timestamp id sorts newest-first alongside ingests;
                // the copied "before" keeps the compare working after relaunch.
                let id = String(format: "%015d", Int(Date().timeIntervalSince1970 * 1000))
                    + "-" + String(UUID().uuidString.prefix(4))
                let outURL = targetDir.appendingPathComponent("enh-\(id).jpg")
                guard await AIImagePrep.writeJPEG(base64: outB64, to: outURL, quality: 0.95) else {
                    throw AIImagePrep.error("The AI didn't return an image. Try again.")
                }
                let beforeURL = targetDir.appendingPathComponent("orig-\(id).jpg")
                try? FileManager.default.copyItem(at: source, to: beforeURL)
                // Never point originalURL at another photo's live file — delete()
                // removes it, so fall back to self, not the source, if the copy fails.
                let originalURL = FileManager.default.fileExists(atPath: beforeURL.path)
                    ? beforeURL : outURL
                await MainActor.run {
                    let newPhoto = EnhancedPhoto(id: id, originalURL: originalURL, enhancedURL: outURL)
                    photos.insert(newPhoto, at: 0)
                    isProcessing = false
                    Haptics.success()
                    compare = newPhoto   // show the before/after immediately
                }
            } catch {
                await MainActor.run {
                    isProcessing = false
                    aiFailure = AIFailure(error, title: "AI enhance failed")
                }
            }
        }
    }

    /// Ask the AI which preset edits would most improve this photo
    /// (`POST /ai-photo`, edit: "suggest"). Results open in SuggestSheet;
    /// tapping one runs the normal aiEdit path.
    private func suggestEdits(_ p: EnhancedPhoto) {
        guard !isProcessing else { return }
        guard requireSignIn() else { return }
        isProcessing = true
        processingText = "Analyzing photo…"
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
        processingText = "Animating photo — about a minute…"
        Haptics.selection()
        let api = model.api          // snapshot on the main actor
        let targetDir = dir
        let source = p.enhancedURL
        let photoID = p.id
        let tapKey = UUID().uuidString
        animateTask = Task {
            do {
                guard let b64 = await AIImagePrep.jpegBase64(at: source, maxDimension: 1280, quality: 0.85) else {
                    throw AIImagePrep.error("Couldn't read that photo.")
                }
                let job = try await api.aiVideoReelClip(
                    imageBase64: b64, mime: "image/jpeg",
                    prompt: nil, seconds: 5, idempotencyKey: tapKey)

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

    /// Gradient banner for the reel maker — shown once ≥2 photos exist, so the
    /// studio's biggest payoff is impossible to miss.
    private var reelBanner: some View {
        Button { showReelStudio = true } label: {
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
                    Text("AI animates your photos and stitches one social-ready video.")
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
            .background(RPGradient.reel)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        }
        .buttonStyle(ScalePressStyle())
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
        .accessibilityLabel(Text("AI enhance this photo"))
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
            Text("Every photo gets the studio treatment")
                .font(.rpHeadline).foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
            Text("Add a photo of your \(space.spaceNoun) above — then one tap does any of this:")
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
                .multilineTextAlignment(.center)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8),
                                GridItem(.flexible(), spacing: 8)], spacing: 8) {
                showcaseChip("moon.stars.fill", "Twilight sky")
                showcaseChip("cloud.sun.fill", "Blue sky")
                if space == .realEstate {
                    showcaseChip("leaf.fill", "Green lawn")
                }
                showcaseChip("sparkles.rectangle.stack.fill", "Declutter")
                showcaseChip("sofa.fill", stagingLabel)
                showcaseChip("play.rectangle.on.rectangle.fill", "Animate to video")
                if space != .realEstate {
                    showcaseChip("text.bubble.fill", "Custom edit")
                }
            }
        }
        .padding(.vertical, 22)
    }

    private func showcaseChip(_ icon: String, _ label: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Theme.accent)
            Text(label)
                .font(.rpCaption.weight(.semibold))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Files

    private func loadExisting() {
        photos = EnhancedPhoto.loadAll(listingID: listing.id)
    }

    private func ingest(_ images: [UIImage]) {
        guard !images.isEmpty else { return }
        isProcessing = true
        processingText = "Enhancing…"
        let targetDir = dir
        DispatchQueue.global(qos: .userInitiated).async {
            for img in images {
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
            DispatchQueue.main.async {
                loadExisting()
                // First photos added become the card's cover image automatically.
                if mainRelPath == nil, let first = photos.first { setMain(first) }
                isProcessing = false
            }
        }
    }

    private func delete(_ p: EnhancedPhoto) {
        let wasMain = isMain(p)
        ImageThumbnails.invalidate(p.enhancedURL)
        try? FileManager.default.removeItem(at: p.enhancedURL)
        try? FileManager.default.removeItem(at: p.originalURL)
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
    let onGenerate: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var prompt = ""
    @State private var isImproving = false       // "Improve my prompt" in flight
    @State private var improveError: String?

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
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// Send the rough idea + this photo through `ai-photo` (edit:
    /// "improve_prompt") and REPLACE the field with the sharper version. The
    /// user can still edit before Generate; the 600-char cap stays enforced by
    /// onChange above. The JPEG prep runs off the main actor.
    private func improvePrompt() {
        let rough = trimmed
        guard !rough.isEmpty, !isImproving else { return }
        isImproving = true
        improveError = nil
        Haptics.selection()
        let api = self.api
        let source = photo.enhancedURL
        Task {
            do {
                guard let b64 = await AIImagePrep.jpegBase64(at: source, maxDimension: 1024, quality: 0.8) else {
                    throw AIImagePrep.error("Couldn't read that photo.")
                }
                let improved = try await api.aiImprovePrompt(
                    imageBase64: b64, mime: "image/jpeg",
                    prompt: String(rough.prefix(300)))
                await MainActor.run {
                    prompt = String(improved.prefix(600))
                    isImproving = false
                    Haptics.success()
                }
            } catch {
                let why = AIFailure(error).fullMessage
                await MainActor.run {
                    isImproving = false
                    improveError = why
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
    @State private var resultPortrait = false
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
            Text("A cinematic AI opening shot for this \(noun) — generated from your exterior photo, so it starts on the real building and flies out.")
                .font(.rpBody)
                .foregroundStyle(Theme.inkDim)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    /// Synthetic-footage disclosure — ALWAYS visible, every state.
    private var disclosure: some View {
        Label("AI-generated — not real drone footage of this \(noun). Say so when you share it.",
              systemImage: "sparkles")
            .font(.rpCaption)
            .foregroundStyle(Theme.warn)
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
            Text("THE PROPERTY").font(.rpKicker).foregroundStyle(Theme.inkDim)
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
            Text("Mood and light only — the building itself comes from your photo.")
                .font(.rpCaption)
                .foregroundStyle(Theme.inkDim)
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
                 : "Widescreen — for the top of a listing video or YouTube.")
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
                    .frame(height: resultPortrait ? 460 : 220)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                    .onAppear { player.play() }
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

                ShareLink(item: url) {
                    Label("Share aerial", systemImage: "square.and.arrow.up")
                        .font(.rpBody.weight(.semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 13)
                        .background(Theme.accentSoft).foregroundStyle(Theme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

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
            guard let label = FlythroughDetailView.regionLabel(from: marks?.first) else { return }
            DispatchQueue.main.async {
                if region.trimmingCharacters(in: .whitespaces).isEmpty { region = label }
                model.setRegion(label, for: id)
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
                try Task.checkCancellation()
                await MainActor.run { statusText = "Submitting…" }

                let job = try await api.aiVideoAerial(request, idempotencyKey: tapKey)
                let pending = PendingAerialJob(job: job, listingID: listingID, submittedAt: Date(),
                                               grounded: job.grounded ?? (photoURL != nil),
                                               aspect: aspectValue)
                pending.save()
                await MainActor.run {
                    grounded = pending.grounded
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
        AerialMeta(grounded: pending.grounded, aspect: pending.aspect).save(for: pending.listingID)

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
            resultPortrait = pending.aspect == "9:16"
            player = AVPlayer(url: dest)
            savedToPhotos = false
            saveError = nil
            failure = nil
            phase = .result
            Haptics.success()
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

    /// Text burned onto the exported reel. Plain Sendable strings — resolved on
    /// the main actor in generate(), rendered as CALayers inside stitch.
    struct ReelCaptions: Sendable {
        let title: String        // listing address (never empty — safe fallback)
        let subtitle: String     // beds/baths/sqft or tagline; "" hides the line
        let watermark: String    // "Made with Rendprop"
    }

    @State private var phase: Phase = .setup
    @State private var selected: [String] = []      // photo ids in tap order = clip order
    @State private var selectedExtras: [URL] = []   // extra clips still switched on
    @State private var seededExtras = false
    @State private var portrait = true              // 9:16 (true) vs 16:9 (false)
    @State private var captionsOn = true            // intro title card + Rendprop mark on export
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

    private var signedIn: Bool { !Config.enableAuth || auth.isSignedIn }
    private var space: SpaceType { listing.isSample ? SpaceType.current : listing.spaceType }
    private var photosScreenName: String {
        space == .realEstate ? "Listing photos" : "\(space.spaceNounCap) photos"
    }
    private var totalSelected: Int { selectedExtras.count + selected.count }
    private var canGenerate: Bool { totalSelected >= 2 && totalSelected <= 9 }

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
                    Button("Close") { dismiss() }
                }
            }
        }
        .interactiveDismissDisabled(phase == .generating || phase == .stitching)
        .onAppear {
            if !seededExtras {
                selectedExtras = extraClipURLs
                seededExtras = true
            }
        }
        .onChange(of: phase) { p in
            let wantHold = (p == .generating || p == .stitching)
            if wantHold && !idleHeld { IdleTimer.hold(); idleHeld = true }
            else if !wantHold && idleHeld { IdleTimer.release(); idleHeld = false }
        }
        .onDisappear {
            workTask?.cancel()
            player?.pause()
            if idleHeld { IdleTimer.release(); idleHeld = false }
        }
        .sheet(isPresented: $showSignIn) { SignInView.forAI("reels") }
    }

    // MARK: Sections

    @ViewBuilder private var setupSection: some View {
        VStack(spacing: 10) {
            Image(systemName: "film.stack")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.accent)
            Text("Make a reel")
                .font(.rpTitle)
                .foregroundStyle(Theme.ink)
            Text(extraClipURLs.isEmpty
                 ? "Pick 2–8 photos in the order you want them. Each becomes a 5-second AI motion clip, stitched into one video ready for Reels, TikTok, or YouTube."
                 : "Your aerial intro opens the reel. Pick the photos that follow — each becomes a 5-second AI motion clip, stitched into one video ready for Reels, TikTok, or YouTube.")
                .font(.rpBody)
                .foregroundStyle(Theme.inkDim)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)

        if signedIn {
            if !extraClipURLs.isEmpty {
                clipsCard
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("PHOTOS").font(.rpKicker).foregroundStyle(Theme.inkDim)
                    Spacer()
                    Text("\(selected.count)/8 selected")
                        .font(.rpCaption)
                        .foregroundStyle(selected.count >= 1 ? Theme.accent : Theme.inkDim)
                }
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()

            VStack(alignment: .leading, spacing: 10) {
                Text("FORMAT").font(.rpKicker).foregroundStyle(Theme.inkDim)
                Picker("Format", selection: $portrait) {
                    Text("9:16 · Reels").tag(true)
                    Text("16:9 · Wide").tag(false)
                }
                .pickerStyle(.segmented)

                Toggle(isOn: $captionsOn) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Captions")
                            .font(.rpBody.weight(.semibold))
                            .foregroundStyle(Theme.ink)
                        Text("Opens on the \(space == .realEstate ? "address" : "name"), plus a small Rendprop mark.")
                            .font(.rpCaption)
                            .foregroundStyle(Theme.inkDim)
                    }
                }
                .tint(Theme.accent)
                .padding(.top, 6)

                Text("MOTION (OPTIONAL)")
                    .font(.rpKicker).foregroundStyle(Theme.inkDim)
                    .padding(.top, 6)
                TextField("Optional: describe the motion — e.g. 'slow push-in, golden-hour feel'",
                          text: $motionPrompt, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
                Text("Each photo clip runs 5 seconds. Leave blank for a smooth cinematic push-in.")
                    .font(.rpCaption).foregroundStyle(Theme.inkDim)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()

            Label(costText, systemImage: "sparkles")
                .font(.rpCaption)
                .foregroundStyle(Theme.inkDim)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button { generate() } label: {
                Label(generateTitle, systemImage: "sparkles")
                    .font(.rpBody.weight(.semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(canGenerate ? Theme.accent : Theme.fillSubtle)
                    .foregroundStyle(canGenerate ? Color.white : Theme.inkDim)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .disabled(!canGenerate)

            Text("Made with AI motion — the photos themselves are unchanged. Any aerial clip is AI-generated scenery, not real drone footage.")
                .font(.rpCaption)
                .foregroundStyle(Theme.inkDim)
                .multilineTextAlignment(.center)
        } else {
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
        if canGenerate { return "Generate reel (\(totalSelected) clips)" }
        if !selectedExtras.isEmpty { return "Select at least 1 photo" }
        return "Select at least 2 photos"
    }

    private var costText: String {
        // No per-unit dollar figures in UI while IAP is off (App Store 3.1.1).
        guard !selected.isEmpty else { return "Each photo becomes a 5-second AI motion clip." }
        return "\(selected.count) photo\(selected.count == 1 ? "" : "s") selected — each becomes a 5-second AI motion clip."
    }

    private var generatingSection: some View {
        VStack(spacing: 14) {
            ProgressView(value: Double(completedClips), total: Double(max(totalClips, 1)))
                .tint(Theme.accent)
            Text(statusText)
                .font(.rpHeadline)
                .foregroundStyle(Theme.ink)
            Text("Each clip takes about a minute. Keep this screen open — the reel stitches itself when the clips are done.")
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
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var stitchingSection: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(1.3)
                .padding(.top, 16)
            Text("Stitching your reel…")
                .font(.rpHeadline)
                .foregroundStyle(Theme.ink)
            Text("Joining the clips into one \(portrait ? "9:16" : "16:9") video on your phone.")
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
            Label("Reel ready", systemImage: "checkmark.circle.fill")
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
            Button("Make another") { resetToSetup() }
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
        workTask?.cancel()
        workTask = nil
        resetToSetup()
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
        phase = .generating
        completedClips = 0
        totalClips = chosen.count
        failedClips = 0
        failure = nil
        statusText = chosen.isEmpty ? "Preparing your clips…" : "Clip 1 of \(chosen.count) — animating…"
        Haptics.selection()
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reel-\(UUID().uuidString)", isDirectory: true)
        workTask = Task {
            do {
                try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
                var clipURLs: [URL] = extras          // ready-made clips lead the reel
                for (i, photo) in chosen.enumerated() {
                    try Task.checkCancellation()
                    await MainActor.run { statusText = "Clip \(i + 1) of \(chosen.count) — animating…" }
                    do {
                        let clip = try await Self.makeClip(photo: photo, prompt: prompt,
                                                           api: api, into: tmpDir, index: i)
                        clipURLs.append(clip)
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
                try await Self.stitch(clips: clipURLs, renderSize: renderSize,
                                      captions: captions, output: outURL)
                try? FileManager.default.removeItem(at: tmpDir)

                try Task.checkCancellation()
                await MainActor.run {
                    reelURL = outURL
                    player = AVPlayer(url: outURL)
                    phase = .done
                    Haptics.success()
                }
            } catch {
                try? FileManager.default.removeItem(at: tmpDir)
                if error is CancellationError || Task.isCancelled { return }
                await MainActor.run {
                    phase = .failed
                    failure = AIFailure(error, title: "Couldn't make the reel")
                }
            }
        }
    }

    /// One photo → 5 s AI motion clip: downscale ≤1280 → jpeg b64 → submit
    /// `ai-video/reel-clip` → poll every 5 s (cap 5 min) → download the mp4 into
    /// `dir`. fal result URLs expire, so the download happens immediately.
    nonisolated private static func makeClip(photo: EnhancedPhoto, prompt: String,
                                             api: APIClient, into dir: URL, index: Int) async throws -> URL {
        guard let ui = UIImage(contentsOfFile: photo.enhancedURL.path) else {
            throw AIImagePrep.error("Couldn't read that photo.")
        }
        let scaled = AIImagePrep.downscaled(ui, maxDimension: 1280)
        guard let jpeg = scaled.jpegData(compressionQuality: 0.85) else {
            throw AIImagePrep.error("Couldn't prepare that photo.")
        }
        let motion = prompt.isEmpty
            ? "Slow, smooth cinematic camera push-in through the scene. Keep the space exactly as photographed — no added objects or people."
            : prompt
        let job = try await api.aiVideoReelClip(imageBase64: jpeg.base64EncodedString(),
                                                mime: "image/jpeg", prompt: motion, seconds: 5,
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

    // MARK: Stitch (AVFoundation — back-to-back, aspect-fill, one export)

    /// Stitch the clips back-to-back into one mp4 at `renderSize`. Every clip is
    /// aspect-FILLED (scale to cover + center-crop) with a layer-instruction
    /// transform computed from its track's naturalSize + preferredTransform, so
    /// portrait/rotated sources render upright. Export waits on a continuation.
    /// `captions` (optional) adds an intro title card + a small Rendprop mark
    /// via AVVideoCompositionCoreAnimationTool — additive, the transform
    /// pipeline is untouched.
    nonisolated private static func stitch(clips: [URL], renderSize: CGSize,
                                           captions: ReelCaptions?, output: URL) async throws {
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw AIImagePrep.error("Couldn't start the video composition.")
        }
        // One composition track + one layer instruction whose transform is
        // re-keyed at each clip boundary (no transitions, so no second track).
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)

        var cursor = CMTime.zero
        var inserted = 0
        for clipURL in clips {
            do {
                let asset = AVURLAsset(url: clipURL)
                guard let srcTrack = try await asset.loadTracks(withMediaType: .video).first else { continue }
                let (naturalSize, preferredTransform) = try await srcTrack.load(.naturalSize, .preferredTransform)
                let timeRange = try await srcTrack.load(.timeRange)
                try videoTrack.insertTimeRange(
                    CMTimeRange(start: timeRange.start, duration: timeRange.duration),
                    of: srcTrack, at: cursor)
                layerInstruction.setTransform(
                    fillTransform(naturalSize: naturalSize,
                                  preferredTransform: preferredTransform,
                                  renderSize: renderSize),
                    at: cursor)
                cursor = CMTimeAdd(cursor, timeRange.duration)
                inserted += 1
            } catch {
                continue   // unreadable clip — skip it; the reel uses the rest
            }
        }
        guard inserted > 0, cursor > .zero else {
            throw AIImagePrep.error("No usable clips to stitch.")
        }

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: cursor)
        instruction.layerInstructions = [layerInstruction]

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = [instruction]

        // Captions (optional): intro title card over the first clip + a small
        // persistent Rendprop mark, composited at EXPORT time via
        // AVVideoCompositionCoreAnimationTool. The tool wants a video layer +
        // a parent layer (video below, overlay above), every frame equal to the
        // render rect. It only applies on EXPORT (never AVPlayer playback) —
        // and this path only exports. The CALayers are deliberately built here
        // in the nonisolated stitch, right before the export, never attached to
        // any live view/layer tree — the standard pattern for titled exports.
        if let captions {
            let renderRect = CGRect(origin: .zero, size: renderSize)
            let videoLayer = CALayer()
            videoLayer.frame = renderRect
            let overlayLayer = CALayer()
            overlayLayer.frame = renderRect
            overlayLayer.masksToBounds = true
            addCaptionLayers(captions, renderSize: renderSize, to: overlayLayer)
            let parentLayer = CALayer()
            parentLayer.frame = renderRect
            // Core Animation's export space is bottom-left; flipping the parent
            // makes the whole tree read top-left (UIKit-style) so the text
            // renders upright and our y-from-top layout math is literal.
            parentLayer.isGeometryFlipped = true
            parentLayer.addSublayer(videoLayer)
            parentLayer.addSublayer(overlayLayer)
            videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
                postProcessingAsVideoLayer: videoLayer, in: parentLayer)
        }

        guard let export = AVAssetExportSession(asset: composition,
                                                presetName: AVAssetExportPresetHighestQuality) else {
            throw AIImagePrep.error("Couldn't create the video exporter.")
        }
        try? FileManager.default.removeItem(at: output)
        export.outputURL = output
        export.outputFileType = .mp4
        export.videoComposition = videoComposition
        export.shouldOptimizeForNetworkUse = true
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { cont.resume() }
        }
        guard export.status == .completed else {
            throw export.error ?? AIImagePrep.error("Couldn't export the stitched reel.")
        }
    }

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

    /// Build the caption CATextLayers on `overlay`: (a) an intro title card —
    /// address (bold) over the facts/tagline line, centered, shown ~2 s then
    /// faded out (opacity CABasicAnimation, beginTime AVCoreAnimationBeginTimeAtZero
    /// + 1.6, duration 0.4, fillMode .forwards, not removed on completion) —
    /// and (b) a small bottom-right "Made with Rendprop" mark at 55% opacity for
    /// the full duration. Coordinates are TOP-LEFT (the parent layer is
    /// geometry-flipped); sizes scale with min(renderSize) so 9:16 and 16:9
    /// exports match. White text with a soft black shadow, safe-area margins.
    nonisolated private static func addCaptionLayers(_ captions: ReelCaptions,
                                                     renderSize: CGSize,
                                                     to overlay: CALayer) {
        let w = renderSize.width, h = renderSize.height
        let unit = min(w, h)                 // 1080 in both 9:16 and 16:9
        let margin = unit * 0.07             // safe-area-ish inset
        let textWidth = w - margin * 2

        // One sized, measured text layer. UIFont is toll-free bridged to CTFont
        // (valid for CATextLayer.font); fontSize still governs the drawn size.
        func makeText(_ text: String, size: CGFloat, weight: UIFont.Weight,
                      alignment: CATextLayerAlignmentMode) -> (CATextLayer, CGFloat) {
            let font = UIFont.systemFont(ofSize: size, weight: weight)
            let measured = (text as NSString).boundingRect(
                with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font], context: nil)
            let layer = CATextLayer()
            layer.string = text
            layer.font = font
            layer.fontSize = size
            layer.foregroundColor = UIColor.white.cgColor
            layer.alignmentMode = alignment
            layer.isWrapped = true
            layer.truncationMode = .end
            layer.contentsScale = 2
            layer.shadowColor = UIColor.black.cgColor
            layer.shadowOpacity = 0.6
            layer.shadowRadius = max(2, size * 0.08)
            layer.shadowOffset = CGSize(width: 0, height: max(1, size * 0.03))
            return (layer, ceil(measured.height) + size * 0.25)
        }

        // --- Intro title card (over the first clip only; every clip is 5 s) ---
        let intro = CALayer()
        intro.frame = CGRect(origin: .zero, size: renderSize)

        let gap = unit * 0.010
        let (titleLayer, titleH) = makeText(captions.title, size: unit * 0.058,
                                            weight: .bold, alignment: .center)
        var blockH = titleH
        var subLayer: CATextLayer?
        var subH: CGFloat = 0
        if !captions.subtitle.isEmpty {
            let (sl, sh) = makeText(captions.subtitle, size: unit * 0.036,
                                    weight: .semibold, alignment: .center)
            subLayer = sl
            subH = sh
            blockH += gap + sh
        }
        let blockTop = h * 0.42 - blockH / 2       // a touch above center
        titleLayer.frame = CGRect(x: margin, y: blockTop, width: textWidth, height: titleH)
        intro.addSublayer(titleLayer)
        if let subLayer {
            subLayer.frame = CGRect(x: margin, y: blockTop + titleH + gap,
                                    width: textWidth, height: subH)
            intro.addSublayer(subLayer)
        }

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1.0
        fade.toValue = 0.0
        fade.beginTime = AVCoreAnimationBeginTimeAtZero + 1.6   // NEVER 0 (0 = "now")
        fade.duration = 0.4
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        intro.add(fade, forKey: "introFade")
        overlay.addSublayer(intro)

        // --- Watermark: bottom-right, whole reel, 55% opacity ---
        // ~10 pt equivalent: 10 / 390 (pt screen width) × 1080 ≈ 28 px.
        let (wm, wmH) = makeText(captions.watermark, size: unit * 0.026,
                                 weight: .semibold, alignment: .right)
        wm.opacity = 0.55
        wm.shadowOpacity = 0.5
        wm.frame = CGRect(x: margin, y: h - margin - wmH, width: textWidth, height: wmH)
        overlay.addSublayer(wm)
    }

    /// Raw buffer space → `renderSize`, aspect-FILL. Applies the source's
    /// preferredTransform first (normalized back to a (0,0) origin — 90°/270°
    /// portrait transforms land the displayed rect at a negative origin), then
    /// scales to cover the render size and centers the overflow (center-crop).
    nonisolated private static func fillTransform(naturalSize: CGSize, preferredTransform: CGAffineTransform,
                                                  renderSize: CGSize) -> CGAffineTransform {
        let displayRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let displayW = abs(displayRect.width)
        let displayH = abs(displayRect.height)
        guard displayW > 0, displayH > 0, displayW.isFinite, displayH.isFinite else { return .identity }

        var t = preferredTransform
        t.tx -= displayRect.minX
        t.ty -= displayRect.minY

        let scale = max(renderSize.width / displayW, renderSize.height / displayH)
        t = t.concatenating(CGAffineTransform(scaleX: scale, y: scale))
        t = t.concatenating(CGAffineTransform(
            translationX: (renderSize.width - displayW * scale) / 2,
            y: (renderSize.height - displayH * scale) / 2))
        return t
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
// LiDAR-only (iPhone/iPad Pro). Scans a room into a 3D model, exports USDZ,
// and previews it with QuickLook. Per-listing file in Documents/FloorPlans/.

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
                        Text(planExists ? "Floor plan ready" : "Scan the room")
                            .font(.rpTitle)
                            .foregroundStyle(Theme.ink)
                        Text(planExists
                             ? "View your floor plan as a flat top-down layout, in 3D, or re-scan to update it."
                             : "Walk the room slowly with your phone. Rendprop builds a floor plan you can view flat or in 3D and share.")
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
                            Text("Re-scan to generate the flat 2D floor plan.")
                                .font(.rpCaption).foregroundStyle(Theme.inkDim)
                                .multilineTextAlignment(.center)
                        }
                        secondaryButton("Re-scan room", "arrow.clockwise") { showScanner = true }
                        ShareLink(item: usdzURL) {
                            Label("Share floor plan", systemImage: "square.and.arrow.up")
                                .font(.rpBody.weight(.semibold))
                                .frame(maxWidth: .infinity).padding(.vertical, 13)
                                .background(Theme.accentSoft).foregroundStyle(Theme.accent)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
        .fullScreenCover(isPresented: $showPlan2D) {
            NavigationStack {
                FloorPlan2DView(jsonURL: planJSONURL, address: listing.address)
                    .navigationTitle("Floor plan")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showPlan2D = false }
                        }
                        ToolbarItem(placement: .primaryAction) {
                            Button { showPlan2D = false; showViewer = true } label: {
                                Label("3D", systemImage: "rotate.3d")
                            }
                        }
                    }
            }
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

/// Hosts RoomPlan's scanning UI + Done/Cancel, exports USDZ on finish.
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
    let exportURL: URL
    var onFinish: ((URL?) -> Void)?

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

        let cancel = makeButton("Cancel", filled: false, action: #selector(cancelTapped))
        let done = makeButton("Done", filled: true, action: #selector(doneTapped))
        let stack = UIStackView(arrangedSubviews: [cancel, done])
        stack.axis = .horizontal
        stack.spacing = 12
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            roomCaptureView.topAnchor.constraint(equalTo: view.topAnchor),
            roomCaptureView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            roomCaptureView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            roomCaptureView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            stack.heightAnchor.constraint(equalToConstant: 50),
        ])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        roomCaptureView.captureSession.run(configuration: config)
        isScanning = true
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isScanning { roomCaptureView.captureSession.stop(); isScanning = false }
    }

    @objc private func doneTapped() {
        // Stops scanning and triggers processing; the delegate fires with the result.
        roomCaptureView.captureSession.stop()
        isScanning = false
    }

    @objc private func cancelTapped() {
        roomCaptureView.captureSession.stop()
        isScanning = false
        onFinish?(nil)
    }

    // Let RoomPlan process the scan into a final result.
    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool { true }

    func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        do {
            try processedResult.export(to: exportURL, exportOptions: .parametric)
            // Also persist the CapturedRoom as JSON so we can draw a flat 2D
            // top-down floor plan (apartment-listing style), not just the 3D model.
            let jsonURL = exportURL.deletingPathExtension().appendingPathExtension("json")
            if let data = try? JSONEncoder().encode(processedResult) {
                try? data.write(to: jsonURL, options: .atomic)
            }
            onFinish?(exportURL)
        } catch {
            onFinish?(nil)
        }
    }

    private func makeButton(_ title: String, filled: Bool, action: Selector) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        b.backgroundColor = filled ? UIColor.systemPurple : UIColor.secondarySystemBackground
        b.setTitleColor(filled ? .white : .systemPurple, for: .normal)
        b.layer.cornerRadius = 12
        b.addTarget(self, action: action, for: .touchUpInside)
        return b
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

// MARK: - 2D top-down floor plan (drawn from the RoomPlan CapturedRoom)
// Renders the scan as a flat blueprint — walls, doors (with swing arcs), windows,
// and labeled furniture — viewed straight down, like an apartment listing.
// Reads the CapturedRoom JSON saved next to the USDZ at scan time.

struct FloorPlan2DView: View {
    let jsonURL: URL
    let address: String

    @State private var room: CapturedRoom?
    @State private var loadFailed = false

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            if let room {
                if room.walls.isEmpty {
                    emptyState("No walls were detected in this scan. Try re-scanning the room slowly.")
                } else {
                    Canvas { ctx, size in
                        FloorPlanRenderer.draw(room: room, in: &ctx, size: size)
                    }
                    .padding(14)
                    .accessibilityLabel(Text("Floor plan of \(address)"))
                }
            } else if loadFailed {
                emptyState("Couldn't open this floor plan. Try re-scanning the room.")
            } else {
                ProgressView().tint(Theme.accent)
            }
        }
        .onAppear(perform: load)
    }

    private func emptyState(_ msg: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "map").font(.system(size: 40, weight: .light)).foregroundStyle(Theme.inkDim)
            Text(msg).font(.rpBody).foregroundStyle(Theme.inkDim)
                .multilineTextAlignment(.center).padding(.horizontal, 40)
        }
    }

    private func load() {
        guard room == nil, !loadFailed else { return }
        let url = jsonURL
        DispatchQueue.global(qos: .userInitiated).async {
            let decoded: CapturedRoom? = {
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(CapturedRoom.self, from: data)
            }()
            DispatchQueue.main.async {
                if let decoded { self.room = decoded } else { self.loadFailed = true }
            }
        }
    }
}

/// Pure drawing of a CapturedRoom as a flat top-down plan. Projects every surface
/// and object onto the floor (X–Z) plane and draws it with SwiftUI Canvas.
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

    static func draw(room: CapturedRoom, in ctx: inout GraphicsContext, size: CGSize) {
        let rawWalls = room.walls.map(seg)
        guard !rawWalls.isEmpty else { return }

        // STRAIGHTEN FIRST. RoomPlan hands back ARKit world space, so a plan drawn
        // as-captured sits at whatever compass heading the phone happened to have —
        // it renders as a skewed diamond. Rotating by the dominant wall angle both
        // makes the plan read orthogonal like a real floor plan AND makes the
        // bounding box we measure the room's true width × depth instead of an
        // inflated diagonal. Do this before anything else touches coordinates.
        let theta = dominantWallAngle(rawWalls)
        let cs = cos(-theta), sn = sin(-theta)
        func rot(_ p: SIMD2<Float>) -> SIMD2<Float> {
            SIMD2<Float>(p.x * cs - p.y * sn, p.x * sn + p.y * cs)
        }
        func rotSeg(_ s: Seg) -> Seg { Seg(a: rot(s.a), b: rot(s.b)) }

        let walls = rawWalls.map(rotSeg)
        let doors = room.doors.map(seg).map(rotSeg)
        let windows = room.windows.map(seg).map(rotSeg)
        let openings = room.openings.map(seg).map(rotSeg)
        let objs = room.objects.map { (o: $0, pts: corners($0).map(rot)) }

        // Bounds over wall endpoints + object footprints.
        var minX = Float.greatestFiniteMagnitude, minY = Float.greatestFiniteMagnitude
        var maxX = -Float.greatestFiniteMagnitude, maxY = -Float.greatestFiniteMagnitude
        func expand(_ p: SIMD2<Float>) {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        for w in walls { expand(w.a); expand(w.b) }
        for o in objs { for c in o.pts { expand(c) } }

        // Room extent measured from the WALLS only — furniture can overhang a wall
        // in a noisy scan, and a sofa sticking through drywall must not inflate the
        // dimension we print on a listing.
        var wMinX = Float.greatestFiniteMagnitude, wMinY = Float.greatestFiniteMagnitude
        var wMaxX = -Float.greatestFiniteMagnitude, wMaxY = -Float.greatestFiniteMagnitude
        var wallPts: [SIMD2<Float>] = []
        for w in walls {
            for p in [w.a, w.b] {
                wallPts.append(p)
                wMinX = min(wMinX, p.x); wMaxX = max(wMaxX, p.x)
                wMinY = min(wMinY, p.y); wMaxY = max(wMaxY, p.y)
            }
        }

        // Asymmetric padding: the left and bottom gutters hold dimension lines.
        let padTop: CGFloat = 30, padRight: CGFloat = 22
        let padLeft: CGFloat = 44, padBottom: CGFloat = 42
        let spanX = max(CGFloat(maxX - minX), 0.001)
        let spanY = max(CGFloat(maxY - minY), 0.001)
        let availW = max(size.width - padLeft - padRight, 1)
        let availH = max(size.height - padTop - padBottom, 1)
        let scale = min(availW / spanX, availH / spanY)
        // A degenerate scan (NaN/inf coordinates) would poison every CGPoint
        // below and trap the Int conversions — draw nothing instead.
        guard scale.isFinite, scale > 0, spanX.isFinite, spanY.isFinite else { return }
        let drawW = spanX * scale, drawH = spanY * scale
        let ox = padLeft + (availW - drawW) / 2
        let oy = padTop + (availH - drawH) / 2
        func P(_ p: SIMD2<Float>) -> CGPoint {
            CGPoint(x: ox + CGFloat(p.x - minX) * scale,
                    y: oy + CGFloat(maxY - p.y) * scale)   // flip vertical → reads upright
        }

        let wallWidth = max(4, 0.10 * scale)   // draw ~10 cm-thick walls

        // Furniture footprints (under the walls). RoomPlan over-guesses uncertain
        // items as "Storage", which clutters the plan — so skip low-confidence
        // detections, draw the box for everything confident, and only LABEL
        // recognizable items (not the generic Storage catch-all) that are big
        // enough on screen to fit readable text.
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
            let boxW = hypot(pts[1].x - pts[0].x, pts[1].y - pts[0].y)
            let boxH = hypot(pts[3].x - pts[0].x, pts[3].y - pts[0].y)
            if !name.isEmpty, o.category != .storage, min(boxW, boxH) > 26 {
                let cx = (pts[0].x + pts[2].x) / 2
                let cy = (pts[0].y + pts[2].y) / 2
                // Explicit ink so labels resolve per light/dark trait (Canvas
                // text gets no default foreground from the surrounding view).
                ctx.draw(Text(name).font(.system(size: 9, weight: .medium))
                            .foregroundColor(Theme.ink),
                         at: CGPoint(x: cx, y: cy))
            }
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

        // ---- Dimensions -------------------------------------------------
        // Width along the bottom, depth up the left side, both in feet and
        // inches, plus an approximate floor area. This is what makes a scan
        // read as a floor plan an agent can actually put on a listing.
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

        // Area is an estimate, and it says so. A phone scan is not a measured
        // survey, and square footage is a number agents get sued over — the
        // convex hull of the wall endpoints is far closer than the bounding box
        // on an angled or L-shaped room, but it is still an approximation.
        let areaSqFt = footprintArea(wallPts) * 10.763_91
        if areaSqFt.isFinite, areaSqFt >= 1, areaSqFt < 1_000_000 {
            ctx.draw(Text("≈ \(Int(areaSqFt.rounded())) sq ft")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Theme.inkDim),
                     at: CGPoint(x: padLeft - 8, y: 16), anchor: .leading)
        }
    }

    /// Length-weighted dominant wall direction, folded into 0–90° because a room's
    /// walls form a right-angled grid: mapping each angle to 4× puts that 90°
    /// period onto a full circle so the directions can be averaged as vectors
    /// (a plain mean would be wrong across the 0°/90° wrap).
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
