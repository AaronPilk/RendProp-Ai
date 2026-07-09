import SwiftUI
import UIKit
import PhotosUI
import CoreImage
import CoreImage.CIFilterBuiltins

struct FlythroughDetailView: View {
    @EnvironmentObject var model: AppModel
    let listing: Listing

    @State private var zillowText = ""

    /// Live copy from the model (listing here is a value snapshot).
    private var currentListing: Listing {
        model.listings.first(where: { $0.id == listing.id }) ?? listing
    }

    private var asset: CaptureAsset? { model.assets[listing.id] }
    private var tour: AppModel.RenderedTour? { model.tours[listing.id] }

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

                // Listing photos — turn phone photos into pro listing images
                NavigationLink {
                    PhotoStudioView(listing: listing)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.title3)
                            .foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Listing photos").font(.rpHeadline).foregroundStyle(Theme.ink)
                            Text("Turn phone photos into pro listing images")
                                .font(.rpCaption).foregroundStyle(Theme.inkDim)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Theme.inkDim)
                    }
                    .card()
                }
                .buttonStyle(.plain)

                // Manage — sold status + Zillow link
                VStack(alignment: .leading, spacing: 12) {
                    Text("MANAGE").font(.rpKicker).foregroundStyle(Theme.inkDim)

                    Button {
                        model.setSold(!currentListing.isSold, for: listing.id)
                        Haptics.success()
                    } label: {
                        Label(currentListing.isSold ? "Mark as active" : "Mark as sold",
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
                    Text("\(listing.metaLine) · \(listing.price.formatted)")
                        .font(.rpBody)
                        .foregroundStyle(Theme.inkDim)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
            }
            .padding()
        }
        .background(Theme.bg)
        .navigationTitle("Flythrough")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { zillowText = currentListing.zillowURL ?? "" }
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

struct PhotoStudioView: View {
    let listing: Listing

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

                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(photos) { p in
                        Button { compare = p } label: { thumb(p) }
                            .buttonStyle(.plain)
                            .contextMenu {
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
                isProcessing = false
            }
        }
    }

    private func delete(_ p: EnhancedPhoto) {
        try? FileManager.default.removeItem(at: p.enhancedURL)
        try? FileManager.default.removeItem(at: p.originalURL)
        loadExisting()
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
