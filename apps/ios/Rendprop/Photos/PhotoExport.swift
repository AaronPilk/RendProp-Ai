import SwiftUI
import UIKit
import Photos
import ImageIO

/// Export copies only. Stored captures, AI outputs and history are never
/// cropped, watermarked, overwritten or removed by an export operation.
enum PhotoExportRenderer {
    enum Destination: String, CaseIterable, Identifiable, Sendable {
        case mls = "MLS", web = "Zillow / web", social = "Social"
        var id: String { rawValue }
    }
    struct Options: Sendable {
        var destination: Destination = .mls
        var includeLabel = true
        var includeOriginals = true
        var original = false
        var aspect: PhotoExportLayout.Aspect = .original
        var framing: PhotoExportLayout.Framing = .fit
        var levelDegrees: Double = 0
    }
    struct Prepared: Identifiable, Sendable {
        let id = UUID()
        let directory: URL
        let images: [URL]
        let files: [URL]
    }
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func prepare(_ photos: [EnhancedPhoto], options: Options) throws -> Prepared {
        guard !photos.isEmpty else { throw Failure(message: "There are no photos to export.") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Rendprop-photos-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            var urls: [URL] = []
            var deliveryFiles: [URL] = []
            for (offset, photo) in photos.enumerated() {
                let url = try autoreleasepool {
                    let history = try PhotoVersionHistory.load(directory: photo.enhancedURL.deletingLastPathComponent())
                    if let named = history.versions[photo.id], named.imageFile != photo.enhancedURL.lastPathComponent {
                        throw PhotoVersionHistory.Failure.changedVersion
                    }
                    let version = history.versions.values.first { $0.imageFile == photo.enhancedURL.lastPathComponent }
                    let source = options.original ? photo.originalURL : photo.enhancedURL
                    try PhotoVersionHistory.requireDownloadReview(imageURL: source)
                    if options.original, source.standardizedFileURL == photo.enhancedURL.standardizedFileURL {
                        throw Failure(message: "An earlier source is missing for photo \(offset + 1). Export its current version instead.")
                    }
                    let suffix = options.original ? (version?.originalVerified == true ? "retained-original" : "earlier-source-unverified") : "edited"
                    let ext = options.original ? source.pathExtension : "jpg"
                    let target = directory.appendingPathComponent(String(format: "%02d", offset + 1) + "-\(suffix).\(ext)")
                    if options.original {
                        // Exact retained bytes. Ratio controls never apply to originals.
                        try FileManager.default.copyItem(at: source, to: target)
                    } else {
                        guard let image = UIImage(contentsOfFile: source.path) else {
                            throw Failure(message: "Couldn't read photo \(offset + 1). Its saved files have not been changed.")
                        }
                        let label = options.destination != .mls && options.includeLabel
                            ? version?.visibleLabel ?? (version == nil ? "Edit history unverified" : nil) : nil
                        let rendered = render(image, aspect: options.aspect, framing: options.framing, label: label,
                                              levelDegrees: options.levelDegrees)
                        guard let data = rendered.jpegData(compressionQuality: 0.97) else {
                            throw Failure(message: "Couldn't prepare photo \(offset + 1). Try again after freeing some space.")
                        }
                        try data.write(to: target, options: .atomic)
                        let caption = version?.caption ?? "Edit history is unavailable. Verify all edits and locate the unaltered source before publishing."
                        let captionURL = directory.appendingPathComponent(String(format: "%02d", offset + 1) + "-disclosure.txt")
                        let framingNote = options.levelDegrees == 0 ? "" : "\nExport copy manually leveled and cropped. The stored source is unchanged."
                        try Data((caption + framingNote + "\nCheck your MLS or advertising platform's disclosure and original-photo rules.\n").utf8)
                            .write(to: captionURL, options: .atomic)
                        deliveryFiles.append(captionURL)
                        if options.includeOriginals, version?.originalVerified == true,
                           photo.originalURL.standardizedFileURL != photo.enhancedURL.standardizedFileURL {
                            let originalURL = directory.appendingPathComponent(String(format: "%02d", offset + 1) + "-retained-original." + photo.originalURL.pathExtension)
                            try PhotoVersionHistory.requireDownloadReview(imageURL: photo.originalURL)
                            try FileManager.default.copyItem(at: photo.originalURL, to: originalURL)
                            urls.append(originalURL); deliveryFiles.append(originalURL)
                        }
                    }
                    return target
                }
                urls.append(url); deliveryFiles.append(url)
            }
            // Photos receives each retained original before its edited version,
            // so the current edit is added last. Files keeps predictable names.
            return Prepared(directory: directory, images: urls,
                            files: deliveryFiles.sorted { $0.lastPathComponent < $1.lastPathComponent })
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    /// Full available pixel dimensions by default, with orientation baked in.
    /// Optional fit keeps the full image inside a bounded canvas without
    /// upscaling; optional crop trims from the center.
    static func render(_ image: UIImage, aspect: PhotoExportLayout.Aspect,
                       framing: PhotoExportLayout.Framing, label: String?, levelDegrees: Double = 0) -> UIImage {
        let cg = image.cgImage
        let rotated = [.left, .right, .leftMirrored, .rightMirrored].contains(image.imageOrientation)
        let rawW = cg?.width ?? Int(image.size.width * image.scale)
        let rawH = cg?.height ?? Int(image.size.height * image.scale)
        let fullWidth = rotated ? rawH : rawW, fullHeight = rotated ? rawW : rawH
        let degrees = levelDegrees.isFinite ? min(5, max(-5, levelDegrees)) : 0
        let angle = degrees * .pi / 180
        // Largest same-aspect rectangle inside the rotated source. Trim edges
        // rather than inventing pixels or enlarging the available photograph.
        let c = abs(cos(angle)), s = abs(sin(angle))
        let cropScale = min(Double(fullWidth) / (Double(fullWidth) * c + Double(fullHeight) * s),
                            Double(fullHeight) / (Double(fullWidth) * s + Double(fullHeight) * c))
        let width = max(1, Int(floor(Double(fullWidth) * cropScale)))
        let height = max(1, Int(floor(Double(fullHeight) * cropScale)))
        let output = PhotoExportLayout.size(width: width, height: height, aspect: aspect, framing: framing)
        let size = CGSize(width: output.width, height: output.height)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size))
            let scale = framing == .fit ? min(1, size.width / CGFloat(width), size.height / CGFloat(height)) : 1
            let drawWidth = CGFloat(fullWidth) * scale, drawHeight = CGFloat(fullHeight) * scale
            context.cgContext.saveGState()
            context.cgContext.translateBy(x: size.width / 2, y: size.height / 2)
            context.cgContext.rotate(by: angle)
            image.draw(in: CGRect(x: -drawWidth / 2, y: -drawHeight / 2, width: drawWidth, height: drawHeight))
            context.cgContext.restoreGState()
            if let label, !label.isEmpty {
                let inset = max(12, min(size.width, size.height) * 0.022)
                let font = UIFont.systemFont(ofSize: max(16, min(size.width, size.height) * 0.026), weight: .semibold)
                let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .left
                let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.white, .paragraphStyle: paragraph]
                let bounds = (label as NSString).boundingRect(with: CGSize(width: size.width - inset * 2, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes, context: nil)
                let strip = min(size.height, ceil(bounds.height) + inset * 2)
                UIColor.black.withAlphaComponent(0.82).setFill()
                context.fill(CGRect(x: 0, y: size.height - strip, width: size.width, height: strip))
                (label as NSString).draw(in: CGRect(x: inset, y: size.height - strip + inset,
                    width: size.width - inset * 2, height: strip - inset * 2), withAttributes: attributes)
            }
        }
    }
}

/// One place to choose delivery, with the safe default requiring no setup:
/// current photos, full available resolution, unchanged aspect, visible labels.
struct PhotoExportSelection: Identifiable {
    let id = UUID()
    let photos: [EnhancedPhoto]
    var original = false
}

struct PhotoExportSheet: View {
    let photos: [EnhancedPhoto]
    private let canExport: () -> Bool
    init(photos: [EnhancedPhoto], original: Bool = false, includeOriginals: Bool = true,
         canExport: @escaping () -> Bool = { true }) {
        self.photos = photos
        self.canExport = canExport
        _original = State(initialValue: original)
        _includeOriginals = State(initialValue: includeOriginals)
    }
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var auth = AuthStore.shared
    @State private var destination: PhotoExportRenderer.Destination = .mls
    @State private var includeLabel = true
    @State private var includeOriginals = true
    @State private var original = false
    @State private var aspect: PhotoExportLayout.Aspect = .original
    @State private var framing: PhotoExportLayout.Framing = .fit
    @State private var levelDegrees = 0.0
    @State private var preview: UIImage?
    @State private var working = false
    @State private var error: String?
    @State private var saved = false
    @State private var prepared: PhotoExportRenderer.Prepared?
    @State private var owner: String?
    @State private var revision: UInt64 = 0
    @State private var workspace: UUID?
    @State private var didCaptureContext = false

    private var versions: [PhotoVersionHistory.Version?] {
        photos.map(\.savedVersion)
    }
    private var verifiedOriginals: Bool { !photos.isEmpty && versions.allSatisfy { $0?.originalVerified == true } }
    private var hasSources: Bool { photos.allSatisfy { $0.originalURL != $0.enhancedURL } }
    private var currentContext: Bool {
        didCaptureContext && canExport() && AuthStore.shared.userID == owner && AuthStore.shared.syncSessionRevision == revision
            && WorkspaceContext.selectedOrgID == workspace
    }
    private var previewKey: String { "\(original)-\(aspect.rawValue)-\(framing.rawValue)-\(destination.rawValue)-\(includeLabel)-\(levelDegrees)" }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let preview {
                        Image(uiImage: preview).resizable().scaledToFit().frame(maxHeight: 240)
                            .frame(maxWidth: .infinity).accessibilityLabel("Export preview of the first photo")
                    }
                    Text(photos.count == 1 ? "Export this photo" : "Export \(photos.count) photos")
                        .font(.headline)
                    if !original, versions.contains(where: { $0?.needsCustomReview == true }) {
                        Text("A selected custom edit still needs comparison. Open Photo versions, compare it with its source and complete the checks before downloading the edited copy. You can still export its earlier source.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Picker("Destination", selection: $destination) {
                        ForEach(PhotoExportRenderer.Destination.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Version", selection: $original) {
                        Text("Selected photos · JPEG copies").tag(false)
                        if hasSources { Text(verifiedOriginals ? "Retained originals" : "Earlier source files").tag(true) }
                    }
                } footer: {
                    Text(original
                         ? (verifiedOriginals ? "The files retained before Rendprop's enhancement. No crop or label is added. Imports may already contain edits made elsewhere."
                            : "Older files have no complete edit history. These earlier sources may already contain AI edits; verify them before publishing.")
                         : "Selected photos download as JPEG (.jpg) copies at full available resolution. AI output resolution may be lower than your capture. Stored photos and originals are never changed.")
                }
                if !original {
                    Section("Framing") {
                        LabeledContent(photos.count == 1 ? "Level" : "Level all selected photos",
                                       value: String(format: "%+.1f°", levelDegrees))
                        Slider(value: $levelDegrees, in: -5...5, step: 0.1) { Text("Level adjustment") }
                            .accessibilityValue(String(format: "%+.1f degrees", levelDegrees))
                        if levelDegrees != 0 { Button("Reset level") { levelDegrees = 0 } }
                        Text("Manual rotation trims the edges of the JPEG copy. It does not correct perspective, widen the view or recover parts of the room outside the photo. Originals stay unchanged.")
                            .font(.caption).foregroundStyle(.secondary)
                        Picker("Aspect ratio", selection: $aspect) {
                            ForEach(PhotoExportLayout.Aspect.allCases) { Text($0.title).tag($0) }
                        }
                        if aspect != .original {
                            Picker("Frame", selection: $framing) {
                                ForEach(PhotoExportLayout.Framing.allCases) { Text($0.rawValue).tag($0) }
                            }
                            Text(framing == .fit ? "Keeps the entire photo and adds white borders."
                                 : "Center crop trims the edges. Check the preview before sharing.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Section("Disclosure") {
                        if destination == .mls {
                            Text("Clean, unbranded photos with matching disclosure text files. Add those captions in your MLS; requirements differ between MLSs.")
                        } else {
                            Toggle("Show edit label on photo", isOn: $includeLabel)
                            Text("Matching disclosure text files are included. On-photo labels describe recorded edits, including virtual staging and decluttering.")
                        }
                        if versions.contains(where: { $0?.originalVerified == true }) {
                            Toggle("Include retained originals", isOn: $includeOriginals)
                            Text("Verified retained source files are paired by number in their original format, which may be HEIC or PNG. Turn this off for JPEG copies only. Imported sources may contain edits made before Rendprop.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Copy disclosure captions") {
                            guard currentContext else { error = "Your account or workspace changed. Reopen the photo to export it."; return }
                            UIPasteboard.general.string = photos.enumerated().map { offset, photo in
                                "Photo \(offset + 1): " + (photo.savedVersion?.caption ?? "Edit history is unavailable. Verify edits and the unaltered source before publishing.")
                            }.joined(separator: "\n\n")
                        }
                        if versions.contains(where: { $0 == nil || $0?.sourceHistoryKnown == false }) {
                            Text("Some older photos have unverified edit history. Check their sources and add accurate disclosures before publishing.")
                                .foregroundStyle(.orange)
                        }
                        Text("Your MLS or advertising platform may require additional wording, original photos or separate disclosures. Check its rules before uploading.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button { start(saveToPhotos: false) } label: { Label(original ? "Share or save source files" : "Download JPEGs · Share or save to Files", systemImage: "square.and.arrow.up") }
                    Button { start(saveToPhotos: true) } label: { Label("Save to Photos", systemImage: "square.and.arrow.down") }
                    Text("For MLS uploads, choose Share or save to Files to keep the .jpg files and matching disclosure captions. Saving to Photos adds images to your camera roll.")
                        .font(.caption).foregroundStyle(.secondary)
                    if working { ProgressView("Preparing photos…") }
                    if saved {
                        Label("Saved to Photos", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        if !original { Text("Copy the disclosure captions above when you upload. Photos does not carry the text files into your listing.").font(.caption) }
                    }
                    if let error { Text(error).foregroundStyle(.red).font(.footnote) }
                }
            }
            .disabled(working)
            .navigationTitle("Export photos").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(working) } }
            .task {
                guard !didCaptureContext else { return }
                owner = AuthStore.shared.userID; revision = AuthStore.shared.syncSessionRevision
                workspace = WorkspaceContext.selectedOrgID; didCaptureContext = true
            }
            .task(id: previewKey) { await updatePreview() }
            .sheet(item: $prepared) { export in ShareSheet(items: export.files) }
            .interactiveDismissDisabled(working)
            .onChange(of: auth.userID) { _ in prepared = nil; preview = nil; dismiss() }
            .onReceive(NotificationCenter.default.publisher(for: .rendpropWorkspaceChanged)) { _ in
                prepared = nil; preview = nil; dismiss()
            }
            .onDisappear {
                // The activity controller may still be reading exported URLs.
                // Keep export copies until the app's temporary directory cleanup.
                preview = nil
            }
        }
    }

    @MainActor private func updatePreview() async {
        guard let photo = photos.first else { return }
        let source = original ? photo.originalURL : photo.enhancedURL
        let selectedAspect = original ? PhotoExportLayout.Aspect.original : aspect
        let selectedFraming = framing
        let selectedLevel = original ? 0 : levelDegrees
        let version = photo.savedVersion
        let label = original || destination == .mls || !includeLabel ? nil
            : (version?.visibleLabel ?? (version == nil ? "Edit history unverified" : nil))
        let key = previewKey
        let result = await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(source as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1000] as CFDictionary) else { return UIImage?.none }
            return PhotoExportRenderer.render(UIImage(cgImage: cg), aspect: selectedAspect, framing: selectedFraming,
                                              label: label, levelDegrees: selectedLevel)
        }.value
        guard !Task.isCancelled, previewKey == key, currentContext else { return }
        preview = result
    }

    @MainActor private func start(saveToPhotos: Bool) {
        guard !working else { return }
        guard currentContext else { error = "Your account or workspace changed. Reopen the photo to export it."; return }
        working = true; error = nil; saved = false
        let options = PhotoExportRenderer.Options(destination: destination, includeLabel: includeLabel,
            includeOriginals: includeOriginals, original: original, aspect: aspect, framing: framing, levelDegrees: levelDegrees)
        Task { @MainActor in
            defer { working = false }
            var output: PhotoExportRenderer.Prepared?
            do {
                let input = photos
                let result = try await Task.detached(priority: .userInitiated) {
                    try PhotoExportRenderer.prepare(input, options: options)
                }.value
                output = result
                guard currentContext else { throw PhotoExportRenderer.Failure(message: "Your account or workspace changed. Reopen the photo to export it.") }
                if saveToPhotos {
                    var status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
                    if status == .notDetermined { status = await PHPhotoLibrary.requestAuthorization(for: .addOnly) }
                    guard status == .authorized || status == .limited else {
                        throw PhotoExportRenderer.Failure(message: "Allow Rendprop to add photos in Settings → Rendprop → Photos, then try again.")
                    }
                    guard currentContext else { throw PhotoExportRenderer.Failure(message: "Your account or workspace changed. Reopen the photo to export it.") }
                    try await PHPhotoLibrary.shared().performChanges {
                        for url in result.images { _ = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url) }
                    }
                    if currentContext { saved = true }
                    try? FileManager.default.removeItem(at: result.directory)
                } else { prepared = result }
            } catch {
                if let output { try? FileManager.default.removeItem(at: output.directory) }
                self.error = error.localizedDescription
            }
        }
    }
}
