import SwiftUI
import UIKit
import PhotosUI
import CoreImage
import CoreImage.CIFilterBuiltins
import MapKit
import CoreLocation
import RoomPlan
import QuickLook

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

    private var shareURL: URL {
        URL(string: "https://rendprop.app/f/\(listing.id.uuidString.prefix(8).lowercased())")!
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
                              message: Text("Fly through \(listing.address) — scroll to walk the home.")) {
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
                        toolButton("Tag rooms", "mappin.and.ellipse", dimmed: asset == nil)
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
    @State private var showViewer = false
    @State private var planExists = false

    private var usdzURL: URL {
        let dir = FileStore.documents.appendingPathComponent("FloorPlans", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(listing.id.uuidString).usdz")
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
                             ? "View your 3D floor plan, or re-scan to update it."
                             : "Walk the room slowly with your phone. Rendprop builds a 3D dollhouse floor plan you can share.")
                            .font(.rpBody).foregroundStyle(Theme.inkDim)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)

                    if planExists {
                        primaryButton("View floor plan", "rotate.3d") { showViewer = true }
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
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 40, weight: .light))
                            .foregroundStyle(Theme.inkDim)
                        Text("3D scanning needs LiDAR")
                            .font(.rpTitle)
                        Text("Floor-plan scanning requires a LiDAR sensor — available on iPhone Pro and iPad Pro models. Your photos and video tour still work on every device.")
                            .font(.rpBody).foregroundStyle(Theme.inkDim)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                }
            }
            .padding()
        }
        .background(Theme.bg)
        .navigationTitle("Floor plan")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { planExists = FileManager.default.fileExists(atPath: usdzURL.path) }
        .fullScreenCover(isPresented: $showScanner) {
            RoomScanView(exportURL: usdzURL) { url in
                showScanner = false
                planExists = FileManager.default.fileExists(atPath: usdzURL.path)
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
