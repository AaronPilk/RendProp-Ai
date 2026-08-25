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

struct FlythroughDetailView: View {
    @EnvironmentObject var model: AppModel
    let listing: Listing

    @State private var zillowText = ""
    @State private var showRoomTagger = false
    @State private var playerRefresh = UUID()

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

    private func toolButton(_ title: String, _ icon: String, dimmed: Bool = false) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.title3)
            Text(title).font(.rpCaption)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Theme.fillSubtle, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .foregroundStyle(dimmed ? Theme.inkDim : Theme.accent)
        .opacity(dimmed ? 0.55 : 1)
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
            ?? URL(string: "https://rendprop.app/f/\(listing.id.uuidString.prefix(8).lowercased())")!
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                // Flythrough preview — the actual scroll-scrub player
                VStack(alignment: .leading, spacing: 8) {
                    Text(playbackURL != nil ? "YOUR TOUR" : "SAMPLE TOUR")
                        .font(.rpKicker).foregroundStyle(Theme.inkDim)
                    PlayerWebView(localVideoURL: playbackURL, roomTags: playbackTags, listing: listing)
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

                // Tools — always visible right under the tour
                HStack(spacing: 10) {
                    NavigationLink { PhotoStudioView(listing: listing) } label: {
                        toolButton("Photos", "photo.on.rectangle.angled")
                    }
                    .buttonStyle(.plain)

                    Button { showRoomTagger = true } label: {
                        toolButton(SpaceType.current == .realEstate ? "Tag rooms" : "Tag areas",
                                   "mappin.and.ellipse", dimmed: asset == nil)
                    }
                    .buttonStyle(.plain)
                    .disabled(asset == nil)

                    NavigationLink { FloorPlanView(listing: listing) } label: {
                        toolButton("Floor plan", "cube.transparent")
                    }
                    .buttonStyle(.plain)
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
                    Text(listing.address).font(.rpTitle)
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
            Text(label)
                .font(.rpCaption)
                .foregroundStyle(Theme.inkDim)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Theme.fillSubtle, in: RoundedRectangle(cornerRadius: 12))
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
    @State private var compare: EnhancedPhoto?

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

                if photos.isEmpty && !isProcessing {
                    VStack(spacing: 8) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.largeTitle).foregroundStyle(Theme.inkDim)
                        Text("Add photos of the property and Rendprop enhances them into bright, crisp listing images — no photographer needed.")
                            .font(.rpBody).foregroundStyle(Theme.inkDim)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.vertical, 40)
                }

                if isProcessing {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Enhancing…").foregroundStyle(Theme.inkDim)
                    }
                    .padding(.vertical, 8)
                }

                if !photos.isEmpty {
                    Text("Tap a photo to compare · long-press to set the main image (shown on your listing card).")
                        .font(.rpCaption).foregroundStyle(Theme.inkDim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(photos) { p in
                        Button { compare = p } label: { thumb(p) }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button { setMain(p) } label: {
                                    Label("Set as main image", systemImage: "star")
                                }
                                Button(role: .destructive) { delete(p) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
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
        .sheet(isPresented: $showLibrary) {
            LibraryImagePicker { imgs in ingest(imgs) }.ignoresSafeArea()
        }
        .sheet(isPresented: $showCamera) {
            CameraPicker { img in ingest([img]) }.ignoresSafeArea()
        }
        .fullScreenCover(item: $compare) { p in PhotoCompareView(photo: p) }
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

    private func loadExisting() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        photos = files
            .filter { $0.lastPathComponent.hasPrefix("enh-") }
            .map { e -> EnhancedPhoto in
                let id = e.deletingPathExtension().lastPathComponent
                    .replacingOccurrences(of: "enh-", with: "")
                let orig = dir.appendingPathComponent("orig-\(id).jpg")
                let origURL = fm.fileExists(atPath: orig.path) ? orig : e
                return EnhancedPhoto(id: id, originalURL: origURL, enhancedURL: e)
            }
            .sorted { $0.id < $1.id }
    }

    private func ingest(_ images: [UIImage]) {
        guard !images.isEmpty else { return }
        isProcessing = true
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
                }
                Spacer()
            }
        }
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
                Text("Blueprint uploaded").font(.rpHeadline)
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

        // Furniture footprints (under the walls).
        for o in room.objects {
            let pts = corners(o).map(P)
            guard pts.count == 4 else { continue }
            var path = Path()
            path.move(to: pts[0]); path.addLine(to: pts[1])
            path.addLine(to: pts[2]); path.addLine(to: pts[3]); path.closeSubpath()
            ctx.fill(path, with: .color(Theme.accent.opacity(0.10)))
            ctx.stroke(path, with: .color(Theme.inkDim.opacity(0.7)), lineWidth: 1)
            let name = label(o.category)
            if !name.isEmpty {
                let cx = (pts[0].x + pts[2].x) / 2
                let cy = (pts[0].y + pts[2].y) / 2
                ctx.draw(Text(name).font(.system(size: 9, weight: .medium)),
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
