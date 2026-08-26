import SwiftUI
import UIKit
import PhotosUI
import CoreImage
import CoreImage.CIFilterBuiltins
import MapKit
import CoreLocation
import RoomPlan
import QuickLook
import simd
import UniformTypeIdentifiers
import AVFoundation   // Reel Studio: composition + stitch + export
import AVKit          // Reel Studio: VideoPlayer preview

struct FlythroughDetailView: View {
    @EnvironmentObject var model: AppModel
    let listing: Listing

    @State private var zillowText = ""
    @State private var showRoomTagger = false
    @State private var playerRefresh = UUID()
    @State private var showAerialIntro = false

    /// Live copy from the model (listing here is a value snapshot).
    private var currentListing: Listing {
        model.listings.first(where: { $0.id == listing.id }) ?? listing
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
        guard let lat = l.latitude, let lon = l.longitude else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    // Industry-specific detail fields the owner filled (non-real-estate).
    private var detailRowFields: [DetailField] {
        SpaceType.current.detailFields.filter { !$0.isURL && !currentListing.detail($0.key).isEmpty }
    }
    private var detailLinkFields: [DetailField] {
        SpaceType.current.detailFields.filter { $0.isURL && !currentListing.detail($0.key).isEmpty }
    }
    private func normalizedURL(_ raw: String) -> URL? {
        let t = raw.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        return URL(string: t.lowercased().hasPrefix("http") ? t : "https://\(t)")
    }
    private func linkLabel(_ f: DetailField) -> String {
        f.key == SpaceType.current.actionURLKey ? SpaceType.current.ctaTitle : f.label
    }

    /// Prefer the rendered tour; fall back to the raw capture.
    private var playbackURL: URL? { tour?.url ?? asset?.localURL }

    /// Room tags, rescaled when the tour was retimed (2× walk → ÷2 timestamps).
    private var playbackTags: [RoomTag] {
        guard let asset else { return [] }
        guard let tour else { return asset.roomTags }
        return asset.roomTags.map { tag in
            RoomTag(name: tag.name, tMs: Int(Double(tag.tMs) / tour.speedFactor))
        }
    }

    /// Prefer the REAL server slug once the tour is published to the cloud; fall
    /// back to the local-only preview link before it's published (contract §4/§5:
    /// never fabricate a slug when a real one exists).
    private var shareURL: URL {
        currentListing.serverShareURL
            ?? URL(string: "https://rendprop.com/f/\(listing.id.uuidString.prefix(8).lowercased())")!
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                // Flythrough preview — the actual scroll-scrub player
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
                    Text(tour != nil
                         ? "Scroll inside to fly through — rendered at \(String(format: "%.2g", tour!.speedFactor))× glide speed, 60fps, instant scrubbing."
                         : (asset != nil
                            ? "Scroll inside to fly through your walkthrough."
                            : "Sample tour — record a walkthrough to see your own home here."))
                        .font(.rpCaption)
                        .foregroundStyle(Theme.inkDim)
                }

                // Share actions
                VStack(spacing: 10) {
                    ShareLink(item: shareURL,
                              subject: Text(listing.address),
                              message: Text("Fly through \(listing.address) — scroll to walk the \(SpaceType.current.spaceNoun).")) {
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
                            UIPasteboard.general.url = shareURL
                            Haptics.success()
                        } label: {
                            Label("Copy link", systemImage: "link")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                        }
                        ShareLink(item: shareURL) {
                            Label("QR / More", systemImage: "qrcode")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    .font(.rpBody)
                }

                // Toolbox — every feature for this listing, one tap away.
                // Same gradient language as Home's showroom, same destinations
                // the old icon row had (plus reel + agent card surfaced).
                VStack(alignment: .leading, spacing: 10) {
                    Text("TOOLBOX").font(.rpKicker).foregroundStyle(Theme.inkDim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                        GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        NavigationLink { PhotoStudioView(listing: listing) } label: {
                            toolCard("Photos & AI edits", "Twilight · staging · declutter",
                                     "wand.and.stars", RPGradient.photo, ai: true)
                        }
                        .buttonStyle(ScalePressStyle())

                        NavigationLink { PhotoStudioView(listing: listing) } label: {
                            toolCard("Make a reel", "Photos → social video",
                                     "film.stack", RPGradient.reel, ai: true)
                        }
                        .buttonStyle(ScalePressStyle())

                        Button { showRoomTagger = true } label: {
                            toolCard(SpaceType.current == .realEstate ? "Tag rooms" : "Tag areas",
                                     asset == nil ? "Needs your own video" : "Tap-to-jump chapters",
                                     "mappin.and.ellipse", RPGradient.rooms, dimmed: asset == nil)
                        }
                        .buttonStyle(ScalePressStyle())
                        .disabled(asset == nil)

                        NavigationLink { FloorPlanView(listing: listing) } label: {
                            toolCard("Floor plan", "Scan in 3D or upload",
                                     "cube.transparent", RPGradient.plan)
                        }
                        .buttonStyle(ScalePressStyle())

                        Button { showAerialIntro = true } label: {
                            toolCard("Aerial intro", "AI opening shot",
                                     "airplane.departure", RPGradient.aerial, ai: true)
                        }
                        .buttonStyle(ScalePressStyle())

                        NavigationLink { AgentCardEditorView() } label: {
                            toolCard(SpaceType.current.profileCardName, "On every link you share",
                                     "person.text.rectangle.fill", RPGradient.agent)
                        }
                        .buttonStyle(ScalePressStyle())
                    }
                }

                // Manage — sold status + Zillow link
                VStack(alignment: .leading, spacing: 12) {
                    Text("MANAGE").font(.rpKicker).foregroundStyle(Theme.inkDim)

                    Button {
                        model.setSold(!currentListing.isSold, for: listing.id)
                        Haptics.success()
                    } label: {
                        Label(currentListing.isSold ? "Mark as active" : "Mark as \(SpaceType.current.archiveVerb)",
                              systemImage: currentListing.isSold ? "arrow.uturn.backward" : "checkmark.seal.fill")
                            .font(.rpBody.weight(.semibold))
                            .foregroundStyle(currentListing.isSold ? Theme.inkDim : Theme.accent)
                    }

                    // Zillow is a real-estate concept — a gym or bar never sees it.
                    // Non-RE types manage their booking/reservation/store links
                    // through the Details card's URL fields instead.
                    if SpaceType.current == .realEstate {
                        Divider()

                        Text("Zillow listing").font(.rpCaption).foregroundStyle(Theme.inkDim)
                        HStack {
                            TextField("Paste Zillow URL", text: $zillowText)
                                .textFieldStyle(.roundedBorder)
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            Button("Save") {
                                model.setZillow(zillowText, for: listing.id)
                                Haptics.selection()
                            }
                            .disabled(zillowText == (currentListing.zillowURL ?? ""))
                        }
                        if let z = currentListing.zillowURLValue {
                            Link(destination: z) {
                                Label("View on Zillow", systemImage: "arrow.up.right.square")
                                    .font(.rpCaption).foregroundStyle(Theme.accent)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()

                // Performance: sample listings demo the stats; real listings
                // stay honest until the beacon pipeline ships.
                VStack(alignment: .leading, spacing: 12) {
                    Text("PERFORMANCE").font(.rpKicker).foregroundStyle(Theme.inkDim)
                    if listing.isSample {
                        HStack(spacing: 10) {
                            statCard("3,214", "Views", "eye")
                            statCard("1:42", "Avg watch", "clock")
                        }
                        HStack(spacing: 10) {
                            statCard("78%", "Scroll depth", "arrow.down.circle")
                            statCard("12", "Leads", "person.crop.circle.badge.checkmark")
                        }
                        Text("Sample data — this is what your dashboard will look like.")
                            .font(.rpCaption)
                            .foregroundStyle(Theme.inkDim)
                    } else {
                        Label("Views, watch time, and leads appear here once your tour is shared.",
                              systemImage: "chart.bar")
                            .font(.rpBody)
                            .foregroundStyle(Theme.inkDim)
                            .padding(.vertical, 8)
                    }
                }
                .card()

                // Listing info
                VStack(alignment: .leading, spacing: 6) {
                    Text(listing.address).font(.rpTitle).foregroundStyle(Theme.ink)
                    Text([listing.subtitleLine, listing.price.cents > 0 ? listing.price.formatted : ""]
                            .filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.rpBody)
                        .foregroundStyle(Theme.inkDim)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()

                // Business details (non real estate) — fields + action links
                if !SpaceType.current.showsPropertyDetails,
                   !detailRowFields.isEmpty || !detailLinkFields.isEmpty {
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

                // Location map (appears once the address geocodes)
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
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card()
                }
            }
            .padding()
        }
        .background(Theme.bg)
        .navigationTitle("Flythrough")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            zillowText = currentListing.zillowURL ?? ""
            geocodeIfNeeded()
        }
        .sheet(isPresented: $showRoomTagger, onDismiss: { playerRefresh = UUID() }) {
            if let a = asset {
                RoomTaggerView(videoURL: a.localURL, tags: roomTagsBinding)
            }
        }
        .sheet(isPresented: $showAerialIntro) {
            AerialIntroSheet(listing: currentListing)
                .environmentObject(model)
        }
    }

    private func geocodeIfNeeded() {
        guard !currentListing.hasCoordinate else { return }
        let addr = listing.address.trimmingCharacters(in: .whitespaces)
        guard !addr.isEmpty, !listing.isSample else { return }
        CLGeocoder().geocodeAddressString(addr) { placemarks, _ in
            guard let c = placemarks?.first?.location?.coordinate else { return }
            DispatchQueue.main.async {
                model.setCoordinate(lat: c.latitude, lon: c.longitude, for: listing.id)
            }
        }
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

// MARK: - Photo studio (phone photos → pro listing images)
// Deterministic, on-device, zero-cost enhancement (shadow lift, vibrance,
// contrast, sharpen). AI declutter / sky-replace can layer on later behind the
// same flow. Files live per-listing in Documents/Photos/<listingID>/.

struct EnhancedPhoto: Identifiable, Hashable {
    let id: String
    let originalURL: URL
    let enhancedURL: URL
}

/// A single map annotation for the listing's geocoded location.
struct MapPin: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
}

struct PhotoStudioView: View {
    @EnvironmentObject var model: AppModel
    let listing: Listing

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

    @State private var photos: [EnhancedPhoto] = []
    @State private var showLibrary = false
    @State private var showCamera = false
    @State private var isProcessing = false
    @State private var processingText = "Enhancing…"
    @State private var compare: EnhancedPhoto?
    @State private var aiError: String?
    @State private var animatedClip: AnimatedClip?   // finished photo→reel clip
    @State private var customEditPhoto: EnhancedPhoto?   // photo awaiting a custom-prompt AI edit
    @State private var showReelStudio = false            // multi-photo → stitched social reel
    @State private var animateTask: Task<Void, Never>?   // photo→clip poll; cancelled on disappear
    @State private var wandPhoto: EnhancedPhoto?         // photo under the visible wand button
    @State private var showWandDialog = false            // wand → AI enhance chooser
    @State private var stagePhoto: EnhancedPhoto?        // photo awaiting a staging style
    @State private var showStageDialog = false           // staging style chooser
    @State private var suggestResult: SuggestResult?     // AI-suggested edits sheet payload

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    private var dir: URL {
        let d = FileStore.documents.appendingPathComponent("Photos/\(listing.id.uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
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

                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(photos) { p in
                        // Wand overlay is a SIBLING of the thumb button (a Button
                        // inside another Button's label never gets the tap).
                        ZStack(alignment: .bottomTrailing) {
                        Button { compare = p } label: { thumb(p) }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text("Listing photo — opens before-and-after compare"))
                            .contextMenu {
                                Menu {
                                    Button { aiEdit(p, "twilight") } label: { Label("Twilight", systemImage: "moon.stars") }
                                    Button { aiEdit(p, "sky") } label: { Label("Blue sky", systemImage: "cloud.sun") }
                                    Button { aiEdit(p, "lawn") } label: { Label("Green lawn", systemImage: "leaf") }
                                    Button { aiEdit(p, "declutter") } label: { Label("Declutter", systemImage: "sparkles.rectangle.stack") }
                                    Menu {
                                        Button { aiEdit(p, "stage", style: "modern") } label: { Text("Modern") }
                                        Button { aiEdit(p, "stage", style: "rustic") } label: { Text("Rustic") }
                                        Button { aiEdit(p, "stage", style: "minimalist") } label: { Text("Minimalist") }
                                        Button { aiEdit(p, "stage", style: "scandinavian") } label: { Text("Scandinavian") }
                                    } label: {
                                        Label("Virtual staging", systemImage: "sofa")
                                    }
                                    Button { customEditPhoto = p } label: { Label("Custom edit…", systemImage: "text.bubble") }
                                } label: {
                                    Label("AI enhance", systemImage: "wand.and.stars")
                                }
                                Button { animate(p) } label: {
                                    Label("Animate (5s clip)", systemImage: "play.rectangle.on.rectangle")
                                }
                                Button { setMain(p) } label: {
                                    Label("Set as main image", systemImage: "star")
                                }
                                Button(role: .destructive) { delete(p) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            wandButton(p)
                        }
                    }
                }

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
        .navigationTitle("Listing photos")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadExisting)
        .onDisappear { animateTask?.cancel() }
        .sheet(isPresented: $showLibrary) {
            LibraryImagePicker { imgs in ingest(imgs) }.ignoresSafeArea()
        }
        .sheet(isPresented: $showCamera) {
            CameraPicker { img in ingest([img]) }.ignoresSafeArea()
        }
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
            Button("Green lawn") { aiEdit(p, "lawn") }
            Button("Declutter") { aiEdit(p, "declutter") }
            Button("Virtual staging…") {
                stagePhoto = p
                // Present after this dialog finishes dismissing.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { showStageDialog = true }
            }
            Button("Custom edit…") { customEditPhoto = p }
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
            Text("AI furnishes the room in the style you pick.")
        }
        .alert("AI enhance failed", isPresented: Binding(
            get: { aiError != nil }, set: { if !$0 { aiError = nil } })) {
            Button("OK", role: .cancel) { aiError = nil }
        } message: { Text(aiError ?? "") }
    }

    /// AI edit (twilight | sky | lawn | declutter | stage | custom) via the
    /// `ai-photo` edge function. `style` rides along for stage, `prompt` for
    /// custom. Saves the result as a NEW photo (keeps the original) and opens
    /// the before/after.
    private func aiEdit(_ p: EnhancedPhoto, _ edit: String,
                        style: String? = nil, prompt: String? = nil) {
        guard let ui = UIImage(contentsOfFile: p.enhancedURL.path) else { return }
        isProcessing = true
        processingText = "Enhancing…"
        Task {
            do {
                let scaled = Self.downscaled(ui, maxDimension: 2048)
                guard let jpeg = scaled.jpegData(compressionQuality: 0.9) else {
                    throw NSError(domain: "AIPhoto", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "Couldn't read that photo."])
                }
                let outB64 = try await model.api.aiPhotoEdit(
                    imageBase64: jpeg.base64EncodedString(), mime: "image/jpeg", edit: edit,
                    style: style, prompt: prompt)
                guard let data = Data(base64Encoded: outB64),
                      let outImg = UIImage(data: data),
                      let outJPEG = outImg.jpegData(compressionQuality: 0.95) else {
                    throw NSError(domain: "AIPhoto", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "The AI didn't return an image. Try again."])
                }
                // Save with the same enh-/orig- convention as ingested photos: a
                // UUID-named PNG was skipped by loadExisting (enh- filter) and lost
                // on relaunch. Timestamp id sorts newest-first alongside ingests;
                // the copied "before" keeps the compare working after relaunch.
                let id = String(format: "%015d", Int(Date().timeIntervalSince1970 * 1000))
                    + "-" + String(UUID().uuidString.prefix(4))
                let outURL = dir.appendingPathComponent("enh-\(id).jpg")
                try outJPEG.write(to: outURL, options: .atomic)
                let beforeURL = dir.appendingPathComponent("orig-\(id).jpg")
                try? FileManager.default.copyItem(at: p.enhancedURL, to: beforeURL)
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
                await MainActor.run { isProcessing = false; aiError = error.localizedDescription }
            }
        }
    }

    /// Ask the AI which preset edits would most improve this photo
    /// (`POST /ai-photo`, edit: "suggest"). Results open in SuggestSheet;
    /// tapping one runs the normal aiEdit path. Errors reuse the aiError alert.
    private func suggestEdits(_ p: EnhancedPhoto) {
        guard !isProcessing, let ui = UIImage(contentsOfFile: p.enhancedURL.path) else { return }
        isProcessing = true
        processingText = "Analyzing photo…"
        Haptics.selection()
        let api = model.api          // snapshot on the main actor
        Task {
            do {
                let scaled = Self.downscaled(ui, maxDimension: 1024)
                guard let jpeg = scaled.jpegData(compressionQuality: 0.8) else {
                    throw NSError(domain: "AIPhoto", code: 3,
                                  userInfo: [NSLocalizedDescriptionKey: "Couldn't read that photo."])
                }
                let results = try await api.aiPhotoSuggest(
                    imageBase64: jpeg.base64EncodedString(), mime: "image/jpeg")
                await MainActor.run {
                    isProcessing = false
                    suggestResult = SuggestResult(photo: p, suggestions: results)
                    Haptics.success()
                }
            } catch {
                await MainActor.run { isProcessing = false; aiError = error.localizedDescription }
            }
        }
    }

    /// Animate a photo into a short AI motion clip (Seedance image-to-video via
    /// the `ai-video` edge function): downscale → base64 → submit → poll every
    /// 6 s → download the mp4 into this listing's Photos dir → offer save/share.
    /// Failures reuse the aiError alert. fal result URLs expire, so the download
    /// happens immediately on completion.
    private func animate(_ p: EnhancedPhoto) {
        guard !isProcessing, let ui = UIImage(contentsOfFile: p.enhancedURL.path) else { return }
        isProcessing = true
        processingText = "Animating photo — about a minute…"
        Haptics.selection()
        let api = model.api          // snapshot on the main actor
        let targetDir = dir
        animateTask = Task {
            do {
                let scaled = Self.downscaled(ui, maxDimension: 1280)
                guard let jpeg = scaled.jpegData(compressionQuality: 0.85) else {
                    throw NSError(domain: "AIVideo", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "Couldn't read that photo."])
                }
                let job = try await api.aiVideoReelClip(
                    imageBase64: jpeg.base64EncodedString(), mime: "image/jpeg",
                    prompt: nil, seconds: 5)

                let deadline = Date().addingTimeInterval(10 * 60)
                var remoteURL: URL?
                while remoteURL == nil {
                    guard Date() < deadline else {
                        throw NSError(domain: "AIVideo", code: 2,
                                      userInfo: [NSLocalizedDescriptionKey: "The clip took too long. Please try again."])
                    }
                    try await Task.sleep(nanoseconds: 6_000_000_000)
                    switch try await api.aiVideoStatus(job) {
                    case .processing:
                        break   // keep waiting; the grid shows the in-flight label
                    case .completed(let videoURL):
                        remoteURL = videoURL
                    case .failed(let message):
                        throw NSError(domain: "AIVideo", code: 3,
                                      userInfo: [NSLocalizedDescriptionKey: message])
                    }
                }
                guard let remoteURL else {
                    throw NSError(domain: "AIVideo", code: 4,
                                  userInfo: [NSLocalizedDescriptionKey: "The AI didn't return a clip. Try again."])
                }

                let (tmp, resp) = try await URLSession.shared.download(from: remoteURL)
                if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw APIError.badResponse(http.statusCode)
                }
                let dest = targetDir.appendingPathComponent(
                    "clip-\(p.id)-\(UUID().uuidString.prefix(4)).mp4")
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tmp, to: dest)

                await MainActor.run {
                    isProcessing = false
                    animatedClip = AnimatedClip(url: dest)
                    Haptics.success()
                }
            } catch is CancellationError {
                // View dismissed mid-animate — stop polling quietly, no error alert.
            } catch {
                await MainActor.run { isProcessing = false; aiError = error.localizedDescription }
            }
        }
    }

    /// Downscale so the base64 upload stays small (and cheaper) without visible loss.
    private static func downscaled(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxDimension else { return image }
        let scale = maxDimension / longest
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }

    private func thumb(_ p: EnhancedPhoto) -> some View {
        Group {
            if let ui = UIImage(contentsOfFile: p.enhancedURL.path) {
                Image(uiImage: ui).resizable().scaledToFill()
            } else {
                Rectangle().fill(Theme.fillSubtle)
            }
        }
        .frame(height: 150)
        .frame(maxWidth: .infinity)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border))
        .overlay(alignment: .topLeading) {
            if isMain(p) {
                Label("Main", systemImage: "star.fill")
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
        .accessibilityLabel(Text("AI enhance this photo"))
    }

    /// Empty state = a menu of what the AI can do, not a blank box.
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
            Text("Add a photo above — then one tap does any of this:")
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
                .multilineTextAlignment(.center)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8),
                                GridItem(.flexible(), spacing: 8)], spacing: 8) {
                showcaseChip("moon.stars.fill", "Twilight sky")
                showcaseChip("cloud.sun.fill", "Blue sky")
                showcaseChip("leaf.fill", "Green lawn")
                showcaseChip("sparkles.rectangle.stack.fill", "Declutter")
                showcaseChip("sofa.fill", "Virtual staging")
                showcaseChip("play.rectangle.on.rectangle.fill", "Animate to video")
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

    private func loadExisting() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? []
        photos = files
            .filter { $0.lastPathComponent.hasPrefix("enh-") }
            .map { e -> EnhancedPhoto in
                let id = e.deletingPathExtension().lastPathComponent
                    .replacingOccurrences(of: "enh-", with: "")
                let orig = dir.appendingPathComponent("orig-\(id).jpg")
                let origURL = fm.fileExists(atPath: orig.path) ? orig : e
                return EnhancedPhoto(id: id, originalURL: origURL, enhancedURL: e)
            }
            // Newest first (matches the AI-edit insert-at-top). Sort by real file
            // creation date, not the id string — mixing UUID and timestamp ids
            // reordered AI edits vs ingests unpredictably across relaunches.
            .sorted { a, b in
                let da = fileCreationDate(a.enhancedURL), db = fileCreationDate(b.enhancedURL)
                return da != db ? da > db : a.id > b.id
            }
    }

    private func fileCreationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
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
                // First photos added become the card's main image automatically.
                if mainRelPath == nil, let first = photos.first { setMain(first) }
                isProcessing = false
            }
        }
    }

    private func delete(_ p: EnhancedPhoto) {
        let wasMain = isMain(p)
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

/// Full-screen before/after compare.
struct PhotoCompareView: View {
    let photo: EnhancedPhoto
    @Environment(\.dismiss) private var dismiss
    @State private var showOriginal = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack {
                Spacer()
                if let ui = UIImage(contentsOfFile: (showOriginal ? photo.originalURL : photo.enhancedURL).path) {
                    Image(uiImage: ui).resizable().scaledToFit()
                        .accessibilityLabel(Text(showOriginal ? "Original photo" : "Enhanced photo"))
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
    /// onChange above.
    private func improvePrompt() {
        let rough = trimmed
        guard !rough.isEmpty, !isImproving,
              let ui = UIImage(contentsOfFile: photo.enhancedURL.path) else { return }
        isImproving = true
        improveError = nil
        Haptics.selection()
        let api = self.api
        Task {
            do {
                let scaled = Self.downscaledForPrompt(ui, maxDimension: 1024)
                guard let jpeg = scaled.jpegData(compressionQuality: 0.8) else {
                    throw NSError(domain: "AIPhoto", code: 4,
                                  userInfo: [NSLocalizedDescriptionKey: "Couldn't read that photo."])
                }
                let improved = try await api.aiImprovePrompt(
                    imageBase64: jpeg.base64EncodedString(), mime: "image/jpeg",
                    prompt: String(rough.prefix(300)))
                await MainActor.run {
                    prompt = String(improved.prefix(600))
                    isImproving = false
                    Haptics.success()
                }
            } catch {
                await MainActor.run {
                    isImproving = false
                    improveError = error.localizedDescription
                }
            }
        }
    }

    /// Downscale so the base64 upload stays small (mirrors PhotoStudioView's
    /// helper — that one is private to its type, so this sheet keeps its own).
    private static func downscaledForPrompt(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxDimension else { return image }
        let scale = maxDimension / longest
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
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
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(Self.friendlyName(s.edit)). \(s.reason)"))
    }
}

// MARK: - AI video results (photo→clip + aerial intro)
// Inline in this file (not standalone files) so they're always in the Xcode
// target without re-running xcodegen — see the repo's new-file-not-in-target rule.

/// A finished AI motion clip on disk — Identifiable so it can drive .sheet(item:).
struct AnimatedClip: Identifiable {
    let id = UUID()
    let url: URL
}

/// Small result sheet for a finished photo animation — save/share the clip.
struct AnimatedClipSheet: View {
    let clip: AnimatedClip
    @Environment(\.dismiss) private var dismiss
    @State private var saved = false

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

            Button {
                UISaveVideoAtPathToSavedPhotosAlbum(clip.url.path, nil, nil, nil)
                saved = true
                Haptics.success()
            } label: {
                Label(saved ? "Saved to Photos" : "Save to Photos",
                      systemImage: saved ? "checkmark.circle.fill" : "square.and.arrow.down")
                    .font(.rpBody.weight(.semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(Theme.accent).foregroundStyle(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .disabled(saved)

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
}

/// AI aerial "establishing shot" generator (POST /ai-video/aerial — Veo on fal).
/// The footage is SYNTHETIC — AI-generated scenery inspired by the address, not
/// real drone footage of the property — and the sheet discloses that at all
/// times. Requires the live backend + a signed-in account (the job runs on the
/// owner's org); shows a sign-in hint otherwise.
struct AerialIntroSheet: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var auth = AuthStore.shared
    @Environment(\.dismiss) private var dismiss
    let listing: Listing

    @State private var seconds = 8
    @State private var isGenerating = false
    @State private var statusText = "Submitting…"
    @State private var clipURL: URL?
    @State private var errorMessage: String?
    @State private var savedToPhotos = false
    @State private var showSignIn = false
    @State private var workTask: Task<Void, Never>?

    private var signedIn: Bool { !Config.enableAuth || auth.isSignedIn }
    private var available: Bool { Config.useLiveBackend && signedIn }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.spacing) {
                    VStack(spacing: 10) {
                        Image(systemName: "airplane.departure")
                            .font(.system(size: 40, weight: .light))
                            .foregroundStyle(Theme.accent)
                        Text("Aerial intro")
                            .font(.rpTitle)
                            .foregroundStyle(Theme.ink)
                        Text("Generate a cinematic AI aerial establishing shot for this listing. It's AI-generated scenery inspired by the address — not actual drone footage of the property.")
                            .font(.rpBody)
                            .foregroundStyle(Theme.inkDim)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)

                    // Synthetic-footage disclosure — ALWAYS visible, every state.
                    Label("AI-generated footage — not real video of this property. Disclose it when you share.",
                          systemImage: "sparkles")
                        .font(.rpCaption)
                        .foregroundStyle(Theme.warn)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Theme.fillSubtle, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                    if let clipURL {
                        resultSection(clipURL)
                    } else if isGenerating {
                        progressSection
                    } else {
                        formSection
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.rpCaption)
                            .foregroundStyle(Theme.warn)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding()
            }
            .background(Theme.bg)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .onDisappear { workTask?.cancel() }
        .sheet(isPresented: $showSignIn) { SignInView() }
    }

    // MARK: - Sections

    @ViewBuilder private var formSection: some View {
        if available {
            VStack(alignment: .leading, spacing: 10) {
                Text("LENGTH").font(.rpKicker).foregroundStyle(Theme.inkDim)
                Picker("Length", selection: $seconds) {
                    Text("4s").tag(4)
                    Text("6s").tag(6)
                    Text("8s").tag(8)
                }
                .pickerStyle(.segmented)
                Text("Landscape 16:9 — made to sit in front of your tour or social cut.")
                    .font(.rpCaption)
                    .foregroundStyle(Theme.inkDim)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()

            Button { generate() } label: {
                Label("Generate aerial", systemImage: "sparkles")
                    .font(.rpBody.weight(.semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(Theme.accent).foregroundStyle(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        } else if !Config.useLiveBackend {
            Label("Aerial intros need the live backend — this build is running offline.",
                  systemImage: "wifi.slash")
                .font(.rpBody)
                .foregroundStyle(Theme.inkDim)
                .padding(.vertical, 12)
        } else {
            VStack(spacing: 10) {
                Label("Sign in to generate aerials — the AI runs on your account.",
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

    private var progressSection: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(1.3)
                .padding(.top, 16)
            Text(statusText)
                .font(.rpHeadline)
                .foregroundStyle(Theme.ink)
            Text("Usually about a minute. Keep this sheet open — the clip downloads the moment it's ready.")
                .font(.rpCaption)
                .foregroundStyle(Theme.inkDim)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }

    private func resultSection(_ url: URL) -> some View {
        VStack(spacing: 12) {
            Label("Aerial ready", systemImage: "checkmark.circle.fill")
                .font(.rpHeadline)
                .foregroundStyle(Theme.good)

            Button {
                UISaveVideoAtPathToSavedPhotosAlbum(url.path, nil, nil, nil)
                savedToPhotos = true
                Haptics.success()
            } label: {
                Label(savedToPhotos ? "Saved to Photos" : "Save to Photos",
                      systemImage: savedToPhotos ? "checkmark.circle.fill" : "square.and.arrow.down")
                    .font(.rpBody.weight(.semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(Theme.accent).foregroundStyle(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .disabled(savedToPhotos)

            ShareLink(item: url) {
                Label("Share aerial", systemImage: "square.and.arrow.up")
                    .font(.rpBody.weight(.semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 13)
                    .background(Theme.accentSoft).foregroundStyle(Theme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            Button("Generate another") {
                clipURL = nil
                savedToPhotos = false
                errorMessage = nil
            }
            .font(.rpBody)
            .foregroundStyle(Theme.inkDim)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Generate (submit → poll → download; fal URLs expire, so download now)

    private func generate() {
        guard available, !isGenerating else { return }
        isGenerating = true
        errorMessage = nil
        statusText = "Submitting…"
        Haptics.selection()
        let api = model.api          // snapshot on the main actor
        let address = listing.address
        let secs = seconds
        let listingID = listing.id
        workTask = Task {
            do {
                let job = try await api.aiVideoAerial(address: address, prompt: nil,
                                                      seconds: secs, aspect: "16:9")
                let deadline = Date().addingTimeInterval(10 * 60)
                var remoteURL: URL?
                while remoteURL == nil {
                    guard Date() < deadline else {
                        throw NSError(domain: "AIVideo", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: "The aerial took too long. Please try again."])
                    }
                    try await Task.sleep(nanoseconds: 6_000_000_000)
                    switch try await api.aiVideoStatus(job) {
                    case .processing(let queuePosition):
                        let label = queuePosition.flatMap { q in
                            q > 0 ? "Generating aerial… (#\(q) in queue)" : nil
                        } ?? "Generating aerial…"
                        await MainActor.run { statusText = label }
                    case .completed(let videoURL):
                        remoteURL = videoURL
                    case .failed(let message):
                        throw NSError(domain: "AIVideo", code: 2,
                                      userInfo: [NSLocalizedDescriptionKey: message])
                    }
                }
                guard let remoteURL else {
                    throw NSError(domain: "AIVideo", code: 3,
                                  userInfo: [NSLocalizedDescriptionKey: "The AI didn't return a video. Try again."])
                }

                await MainActor.run { statusText = "Downloading your aerial…" }
                let (tmp, resp) = try await URLSession.shared.download(from: remoteURL)
                if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw APIError.badResponse(http.statusCode)
                }
                let dest = FileStore.documents
                    .appendingPathComponent("aerial-\(listingID.uuidString).mp4")
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tmp, to: dest)

                await MainActor.run {
                    clipURL = dest
                    isGenerating = false
                    Haptics.success()
                }
            } catch is CancellationError {
                // Sheet closed mid-generate — drop the work quietly.
            } catch {
                await MainActor.run {
                    isGenerating = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Reel Studio (multi-photo → AI motion clips → one stitched social video)
// Pick 2–8 listing photos; each becomes a 5 s Seedance motion clip via
// POST /ai-video/reel-clip (sequential submit → poll → download), then the
// clips are stitched ON-DEVICE with AVFoundation into a single 9:16 or 16:9
// mp4 saved to Documents/reels/. Inline here per the new-file-not-in-target rule.

struct ReelStudioView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var auth = AuthStore.shared
    @Environment(\.dismiss) private var dismiss
    let listing: Listing
    let photos: [EnhancedPhoto]

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
    @State private var errorMessage: String?
    @State private var showSignIn = false
    @State private var workTask: Task<Void, Never>?

    private var signedIn: Bool { !Config.enableAuth || auth.isSignedIn }
    private var available: Bool { Config.useLiveBackend && signedIn }

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
        .onDisappear { workTask?.cancel() }
        .sheet(isPresented: $showSignIn) { SignInView() }
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
            Text("Pick 2–8 photos in the order you want them. Each becomes a 5-second AI motion clip, stitched into one video ready for Reels, TikTok, or YouTube.")
                .font(.rpBody)
                .foregroundStyle(Theme.inkDim)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)

        if available {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("PHOTOS").font(.rpKicker).foregroundStyle(Theme.inkDim)
                    Spacer()
                    Text("\(selected.count)/8 selected")
                        .font(.rpCaption)
                        .foregroundStyle(selected.count >= 2 ? Theme.accent : Theme.inkDim)
                }
                LazyVGrid(columns: selectColumns, spacing: 8) {
                    ForEach(photos) { p in selectThumb(p) }
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
                        Text("Opens on the \(SpaceType.current == .realEstate ? "address" : "name"), plus a small Rendprop mark.")
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
                Text("Each clip runs 5 seconds. Leave blank for a smooth cinematic push-in.")
                    .font(.rpCaption).foregroundStyle(Theme.inkDim)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()

            Label(costText, systemImage: "dollarsign.circle")
                .font(.rpCaption)
                .foregroundStyle(Theme.inkDim)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button { generate() } label: {
                Label(selected.count < 2 ? "Select at least 2 photos"
                                         : "Generate reel (\(selected.count) clips)",
                      systemImage: "sparkles")
                    .font(.rpBody.weight(.semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(selected.count < 2 ? Theme.fillSubtle : Theme.accent)
                    .foregroundStyle(selected.count < 2 ? Theme.inkDim : Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .disabled(selected.count < 2)

            Text("Made with AI motion — the photos themselves are unchanged.")
                .font(.rpCaption)
                .foregroundStyle(Theme.inkDim)
                .frame(maxWidth: .infinity, alignment: .center)
        } else if !Config.useLiveBackend {
            Label("Reels need the live backend — this build is running offline.",
                  systemImage: "wifi.slash")
                .font(.rpBody)
                .foregroundStyle(Theme.inkDim)
                .padding(.vertical, 12)
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

    private var costText: String {
        guard !selected.isEmpty else { return "About $0.24 per clip (5-second AI motion)." }
        let total = String(format: "$%.2f", Double(selected.count) * 0.24)
        return "About $0.24 per clip — \(selected.count) selected ≈ \(total)."
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
                Button {
                    UISaveVideoAtPathToSavedPhotosAlbum(reelURL.path, nil, nil, nil)
                    savedToPhotos = true
                    Haptics.success()
                } label: {
                    Label(savedToPhotos ? "Saved to Photos" : "Save to Photos",
                          systemImage: savedToPhotos ? "checkmark.circle.fill" : "square.and.arrow.down")
                        .font(.rpBody.weight(.semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(Theme.accent).foregroundStyle(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .disabled(savedToPhotos)

                ShareLink(item: reelURL) {
                    Label("Share reel", systemImage: "square.and.arrow.up")
                        .font(.rpBody.weight(.semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 13)
                        .background(Theme.accentSoft).foregroundStyle(Theme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            Button("Make another") { resetToSetup() }
                .font(.rpBody)
                .foregroundStyle(Theme.inkDim)
        }
        .frame(maxWidth: .infinity)
    }

    private var failedSection: some View {
        VStack(spacing: 12) {
            Label("Couldn't make the reel", systemImage: "exclamationmark.triangle")
                .font(.rpHeadline)
                .foregroundStyle(Theme.warn)
            Text(errorMessage ?? "Something went wrong. Please try again.")
                .font(.rpBody)
                .foregroundStyle(Theme.inkDim)
                .multilineTextAlignment(.center)
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
                Group {
                    if let ui = UIImage(contentsOfFile: p.enhancedURL.path) {
                        Image(uiImage: ui).resizable().scaledToFill()
                    } else {
                        Rectangle().fill(Theme.fillSubtle)
                    }
                }
                .frame(height: 100)
                .frame(maxWidth: .infinity)
                .clipped()
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
        .buttonStyle(.plain)
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
        errorMessage = nil
        completedClips = 0
        totalClips = 0
        failedClips = 0
        phase = .setup
    }

    // MARK: Generate (sequential clips → on-device stitch)

    private func generate() {
        guard available, phase == .setup else { return }
        let chosen = selected.compactMap { id in photos.first(where: { $0.id == id }) }
        guard chosen.count >= 2 else { return }
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
        errorMessage = nil
        statusText = "Clip 1 of \(chosen.count) — animating…"
        Haptics.selection()
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reel-\(UUID().uuidString)", isDirectory: true)
        workTask = Task {
            do {
                try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
                var clipURLs: [URL] = []
                for (i, photo) in chosen.enumerated() {
                    try Task.checkCancellation()
                    await MainActor.run { statusText = "Clip \(i + 1) of \(chosen.count) — animating…" }
                    do {
                        let clip = try await Self.makeClip(photo: photo, prompt: prompt,
                                                           api: api, into: tmpDir, index: i)
                        clipURLs.append(clip)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        // One bad clip never kills the reel — note it and move on.
                        await MainActor.run { failedClips += 1 }
                    }
                    await MainActor.run { completedClips = i + 1 }
                }
                guard !clipURLs.isEmpty else {
                    throw NSError(domain: "ReelStudio", code: 20,
                                  userInfo: [NSLocalizedDescriptionKey: "None of the clips could be generated. Please try again."])
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
                    errorMessage = error.localizedDescription
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
            throw NSError(domain: "ReelStudio", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Couldn't read that photo."])
        }
        let scaled = downscaledForReel(ui, maxDimension: 1280)
        guard let jpeg = scaled.jpegData(compressionQuality: 0.85) else {
            throw NSError(domain: "ReelStudio", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Couldn't prepare that photo."])
        }
        let motion = prompt.isEmpty
            ? "Slow, smooth cinematic camera push-in through the scene. Keep the space exactly as photographed — no added objects or people."
            : prompt
        let job = try await api.aiVideoReelClip(imageBase64: jpeg.base64EncodedString(),
                                                mime: "image/jpeg", prompt: motion, seconds: 5)

        let deadline = Date().addingTimeInterval(5 * 60)
        var remoteURL: URL?
        while remoteURL == nil {
            guard Date() < deadline else {
                throw NSError(domain: "ReelStudio", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "The clip took too long."])
            }
            try await Task.sleep(nanoseconds: 5_000_000_000)
            switch try await api.aiVideoStatus(job) {
            case .processing:
                break   // keep polling — the caller shows "Clip X of N"
            case .completed(let videoURL):
                remoteURL = videoURL
            case .failed(let message):
                throw NSError(domain: "ReelStudio", code: 4,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        guard let remoteURL else {
            throw NSError(domain: "ReelStudio", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "The AI didn't return a clip."])
        }

        let (tmp, resp) = try await URLSession.shared.download(from: remoteURL)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw APIError.badResponse(http.statusCode)
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
            throw NSError(domain: "ReelStudio", code: 30,
                          userInfo: [NSLocalizedDescriptionKey: "Couldn't start the video composition."])
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
            throw NSError(domain: "ReelStudio", code: 31,
                          userInfo: [NSLocalizedDescriptionKey: "No usable clips to stitch."])
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
            throw NSError(domain: "ReelStudio", code: 32,
                          userInfo: [NSLocalizedDescriptionKey: "Couldn't create the video exporter."])
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
            throw export.error ?? NSError(domain: "ReelStudio", code: 33,
                                          userInfo: [NSLocalizedDescriptionKey: "Couldn't export the stitched reel."])
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
        guard displayW > 0, displayH > 0 else { return .identity }

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

    /// Downscale so the base64 upload stays small (and cheaper) without visible loss.
    nonisolated private static func downscaledForReel(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxDimension else { return image }
        let scale = maxDimension / longest
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }
}

// MARK: - Pickers

/// Multi-select Photos picker (images only).
struct LibraryImagePicker: UIViewControllerRepresentable {
    let onPicked: ([UIImage]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 15
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
        let walls = room.walls.map(seg)
        guard !walls.isEmpty else { return }
        let doors = room.doors.map(seg)
        let windows = room.windows.map(seg)
        let openings = room.openings.map(seg)

        // Bounds over wall endpoints + object footprints.
        var minX = Float.greatestFiniteMagnitude, minY = Float.greatestFiniteMagnitude
        var maxX = -Float.greatestFiniteMagnitude, maxY = -Float.greatestFiniteMagnitude
        func expand(_ p: SIMD2<Float>) {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        for w in walls { expand(w.a); expand(w.b) }
        for o in room.objects { for c in corners(o) { expand(c) } }

        let pad: CGFloat = 24
        let spanX = max(CGFloat(maxX - minX), 0.001)
        let spanY = max(CGFloat(maxY - minY), 0.001)
        let scale = min((size.width - pad*2) / spanX, (size.height - pad*2) / spanY)
        let drawW = spanX * scale, drawH = spanY * scale
        let ox = (size.width - drawW) / 2
        let oy = (size.height - drawH) / 2
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
        for o in room.objects {
            if o.confidence == .low { continue }
            let pts = corners(o).map(P)
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
