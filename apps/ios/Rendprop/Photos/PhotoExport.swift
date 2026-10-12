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
    /// A file that rides along with the photos in a listing package (build 60:
    /// "Share everything"): the walkthrough tour, a reel, the aerial opening,
    /// a moving photo, the 3D scan, or the listing-details note. `name` is the
    /// file name inside the archive; `note` is one line for the README.
    struct Extra: Identifiable, Hashable, Sendable {
        let id = UUID()
        let name: String
        let url: URL
        let note: String
    }
    /// An empty prepared directory for a package with no photos — a listing
    /// that only has videos still has something worth handing over.
    static func prepareEmpty() throws -> Prepared {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Rendprop-photos-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return Prepared(directory: directory, images: [], files: [])
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
                        var withheldNote = ""
                        if options.includeOriginals, version?.originalVerified == true,
                           photo.originalURL.standardizedFileURL != photo.enhancedURL.standardizedFileURL {
                            let originalURL = directory.appendingPathComponent(String(format: "%02d", offset + 1) + "-retained-original." + photo.originalURL.pathExtension)
                            try PhotoVersionHistory.requireDownloadReview(imageURL: photo.originalURL)
                            try FileManager.default.copyItem(at: photo.originalURL, to: originalURL)
                            urls.append(originalURL); deliveryFiles.append(originalURL)
                        }
                        // Build 61 — every other version the app holds for this
                        // photo, not only the gallery one and its untouched
                        // original: the enhancement made before any AI edit,
                        // each earlier AI edit, a superseded staging ("it needs
                        // to be EVERY image associated and labeled" — Aaron,
                        // TestFlight 60). Oldest first, numbered by position in
                        // the photo's history, named by what each one is, exact
                        // stored bytes, each with its own disclosure note. The
                        // gallery version keeps '-edited'. A custom output that
                        // was never reviewed is withheld exactly as it is from a
                        // direct download, and the photo's note says so.
                        if options.includeOriginals, let version {
                            let photoDirectory = photo.enhancedURL.deletingLastPathComponent()
                            let others = history.history(for: version.id).filter { $0.id != version.id }
                                .sorted { $0.createdAt != $1.createdAt ? $0.createdAt < $1.createdAt : $0.id < $1.id }
                            var withheld = 0
                            for (position, other) in others.enumerated() {
                                let stored = photoDirectory.appendingPathComponent(other.imageFile)
                                guard FileManager.default.fileExists(atPath: stored.path),
                                      (try? PhotoVersionHistory.requireDownloadReview(imageURL: stored)) != nil else { withheld += 1; continue }
                                let stem = String(format: "%02d", offset + 1) + "-version-\(position + 1)-" + other.exportSlug
                                let copy = directory.appendingPathComponent(stem + "." + (stored.pathExtension.isEmpty ? "jpg" : stored.pathExtension))
                                try FileManager.default.copyItem(at: stored, to: copy)
                                let note = directory.appendingPathComponent(stem + "-disclosure.txt")
                                try Data((other.title + ".\n" + other.caption + "\nCheck your MLS or advertising platform's disclosure and original-photo rules.\n").utf8)
                                    .write(to: note, options: .atomic)
                                urls.append(copy); deliveryFiles.append(copy); deliveryFiles.append(note)
                            }
                            if withheld > 0 {
                                withheldNote = "\n\(withheld) other version\(withheld == 1 ? " of this photo was" : "s of this photo were") not included: not yet reviewed, or no longer on this phone."
                            }
                        }
                        try Data((caption + framingNote + withheldNote + "\nCheck your MLS or advertising platform's disclosure and original-photo rules.\n").utf8)
                            .write(to: captionURL, options: .atomic)
                        deliveryFiles.append(captionURL)
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

    /// One file for the whole export, so an agent can hand every photo and its
    /// disclosure to whoever runs their file (a transaction coordinator, the
    /// office, a client) as a single attachment. The archive holds exactly the
    /// files `prepare` produced, in their numbered order, plus a short README
    /// that says what the numbers and the disclosure files are. The prepared
    /// files stay in place; the archive sits beside them in the same temporary
    /// directory so the usual cleanup removes both.
    static func package(_ prepared: Prepared, archiveName: String, extras: [Extra] = [], now: Date = Date()) throws -> URL {
        guard !prepared.files.isEmpty || !extras.isEmpty else { throw Failure(message: "There are no photos to package.") }
        let versionCount = prepared.files.filter { $0.lastPathComponent.contains("-version-") && !$0.lastPathComponent.hasSuffix("-disclosure.txt") }.count
        let photoCount = prepared.files.filter { ["jpg", "jpeg"].contains($0.pathExtension.lowercased()) && !$0.lastPathComponent.contains("retained-original") && !$0.lastPathComponent.contains("-version-") }.count
        let originalCount = prepared.files.filter { $0.lastPathComponent.contains("retained-original") }.count
        let disclosureCount = prepared.files.filter { $0.lastPathComponent.hasSuffix("-disclosure.txt") }.count
        let title = ZipArchive.safeFileName(archiveName, fallback: "Rendprop")
        let formatter = DateFormatter(); formatter.dateStyle = .long; formatter.timeStyle = .none
        let whole = !extras.isEmpty
        var readme = "\(title)\n\(whole ? "Listing package" : "Photos") exported from Rendprop on \(formatter.string(from: now)).\n\n"
        let total = prepared.files.count + extras.count
        readme += "\(total) file\(total == 1 ? "" : "s"): "
        readme += "\(photoCount) photo\(photoCount == 1 ? "" : "s") (numbered in gallery order; '-edited' is the version shown in the app)"
        if originalCount > 0 { readme += ", \(originalCount) retained original\(originalCount == 1 ? "" : "s") (same number, '-retained-original': the untouched photo as captured or imported)" }
        if versionCount > 0 { readme += ", \(versionCount) other version\(versionCount == 1 ? "" : "s") (same number, '-version-<n>-<what it is>', in the order they were made)" }
        if disclosureCount > 0 { readme += ", \(disclosureCount) disclosure note\(disclosureCount == 1 ? "" : "s") (same name as the image, '-disclosure.txt')" }
        if whole { readme += ", \(extras.count) more file\(extras.count == 1 ? "" : "s") listed below" }
        readme += ".\n\n"
        if versionCount > 0 {
            readme += "Every image Rendprop holds for a photo is here: the untouched original, each enhancement or AI edit in the order it was made, and the version shown in the app. "
            readme += "The label in the file name says what each one is (enhanced, virtually-staged-modern, decluttered, twilight-sky, ...).\n"
        }
        if disclosureCount > 0 {
            readme += "Each -disclosure.txt describes the edits recorded for the image with the same name, including virtual staging and decluttering. "
            readme += "Add those captions wherever the photo is published; MLS and advertising rules differ, so check yours before uploading.\n"
        } else if photoCount > 0 || originalCount > 0 {
            readme += "These are source files as retained by Rendprop. Check your MLS or advertising platform's rules before publishing.\n"
        }
        if whole {
            readme += "\nAlso in this package:\n"
            for extra in extras { readme += "  \(extra.name) — \(extra.note)\n" }
            readme += "\nVideos made with AI motion (a reel, an aerial opening, a moving photo) are AI-generated and should be described as such wherever they are published.\n"
        }
        let readmeURL = prepared.directory.appendingPathComponent("README.txt")
        try Data(readme.utf8).write(to: readmeURL, options: .atomic)
        var entries = [ZipArchive.Entry(name: "README.txt", url: readmeURL)]
        for file in prepared.files { entries.append(ZipArchive.Entry(name: file.lastPathComponent, url: file)) }
        var used = Set(entries.map { $0.name.lowercased() })
        for extra in extras {
            // The archive reads straight from the extra's own file: nothing is
            // copied, nothing is moved, the listing's files stay where they are.
            var name = ZipArchive.safeFileName(extra.name, fallback: "file")
            var attempt = 1
            while used.contains(name.lowercased()) {
                attempt += 1
                let base = (extra.name as NSString).deletingPathExtension, ext = (extra.name as NSString).pathExtension
                name = ZipArchive.safeFileName(ext.isEmpty ? "\(base)-\(attempt)" : "\(base)-\(attempt).\(ext)", fallback: "file-\(attempt)")
            }
            used.insert(name.lowercased())
            entries.append(ZipArchive.Entry(name: name, url: extra.url))
        }
        let archiveURL = prepared.directory.appendingPathComponent(whole ? "\(title) listing.zip" : "\(title) photos.zip")
        try ZipArchive.write(entries, to: archiveURL, modified: now)
        return archiveURL
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
    /// Names the ZIP archive ("2050 Laney Pond Dr photos.zip"); the listing's
    /// address where the caller has one.
    let archiveName: String
    /// Build 60 "Share everything": the listing's videos, 3D scan and details
    /// note that travel with the photos. Empty for an ordinary photo export.
    let extras: [PhotoExportRenderer.Extra]
    private let canExport: () -> Bool
    init(photos: [EnhancedPhoto], original: Bool = false, includeOriginals: Bool = true,
         archiveName: String = "Rendprop", extras: [PhotoExportRenderer.Extra] = [],
         canExport: @escaping () -> Bool = { true }) {
        self.photos = photos
        self.archiveName = archiveName
        self.extras = extras
        self.canExport = canExport
        _original = State(initialValue: original)
        _includeOriginals = State(initialValue: includeOriginals)
        // Several photos default to one archive: that is the shape a
        // transaction coordinator or office can actually receive. One photo
        // stays a plain file so AirDrop and Messages show the image itself.
        // A whole-listing package is always offered as one archive first.
        _asArchive = State(initialValue: photos.count > 1 || !extras.isEmpty)
    }
    private var wholeListing: Bool { !extras.isEmpty }
    private var canArchive: Bool { photos.count > 1 || wholeListing }
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var auth = AuthStore.shared
    @State private var destination: PhotoExportRenderer.Destination = .mls
    @State private var includeLabel = true
    @State private var includeOriginals = true
    @State private var original = false
    @State private var aspect: PhotoExportLayout.Aspect = .original
    @State private var framing: PhotoExportLayout.Framing = .fit
    @State private var levelDegrees = 0.0
    @State private var asArchive = false
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
    private var hasSources: Bool { !photos.isEmpty && photos.allSatisfy { $0.originalURL != $0.enhancedURL } }
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
                    Text(wholeListing
                         ? "Export the whole listing — \(photos.count) photo\(photos.count == 1 ? "" : "s") and \(extras.count) more file\(extras.count == 1 ? "" : "s")"
                         : (photos.count == 1 ? "Export this photo" : "Export \(photos.count) photos"))
                        .font(.headline)
                    if wholeListing {
                        Text(extras.map(\.name).joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("export.packageExtras")
                    }
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
                            Toggle("Include retained originals and every other version", isOn: $includeOriginals)
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
                if canArchive {
                    Section("Deliver as") {
                        Picker("Deliver as", selection: $asArchive) {
                            Text("One ZIP file").tag(true)
                            Text("Separate files").tag(false)
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("export.deliverAs")
                        Text(asArchive
                             ? (wholeListing
                                ? "One file with the tour, every photo and every version of it, their disclosure notes, the other videos, a listing-details note and a short README — everything a transaction coordinator, your office or a client needs. It opens on any Mac, PC or phone."
                                : "One file with every photo and every version of it, their disclosure notes and a short README — the easiest thing to send to a transaction coordinator, your office or a client. It opens on any Mac, PC or phone.")
                             : (wholeListing
                                ? "Photos, originals, every other version, disclosure notes, videos and listing details are shared as separate files. Better for AirDrop to another iPhone."
                                : "Each photo, original, other version and disclosure note is shared as its own file. Better for AirDrop to another iPhone."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button { start(saveToPhotos: false) } label: {
                        Label(asArchive && canArchive ? "Share one ZIP file" : (wholeListing ? "Share all files · Save to Files" : (original ? "Share or save source files" : "Download JPEGs · Share or save to Files")),
                              systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("export.share")
                    if !photos.isEmpty {
                        Button { start(saveToPhotos: true) } label: { Label("Save to Photos", systemImage: "square.and.arrow.down") }
                    }
                    Text(asArchive && canArchive
                         ? "The ZIP keeps the .jpg files and matching disclosure captions together for MLS uploads. Saving to Photos adds the images to your camera roll instead."
                         : "For MLS uploads, choose Share or save to Files to keep the .jpg files and matching disclosure captions. Saving to Photos adds images to your camera roll.")
                        .font(.caption).foregroundStyle(.secondary)
                    if working { ProgressView(wholeListing ? "Preparing listing package…" : "Preparing photos…") }
                    if saved {
                        Label("Saved to Photos", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        if !original { Text("Copy the disclosure captions above when you upload. Photos does not carry the text files into your listing.").font(.caption) }
                    }
                    if let error { Text(error).foregroundStyle(.red).font(.footnote) }
                }
            }
            .disabled(working)
            .navigationTitle(wholeListing ? "Share everything" : "Export photos").navigationBarTitleDisplayMode(.inline)
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
        // Package only for a share: Photos receives the images themselves.
        let wantsArchive = asArchive && canArchive && !saveToPhotos
        let archiveTitle = archiveName
        let packageExtras = saveToPhotos ? [] : extras
        Task { @MainActor in
            defer { working = false }
            var output: PhotoExportRenderer.Prepared?
            do {
                let input = photos
                let (result, archive) = try await Task.detached(priority: .userInitiated) { () -> (PhotoExportRenderer.Prepared, URL?) in
                    let prepared = input.isEmpty ? try PhotoExportRenderer.prepareEmpty() : try PhotoExportRenderer.prepare(input, options: options)
                    do {
                        let archive = wantsArchive ? try PhotoExportRenderer.package(prepared, archiveName: archiveTitle, extras: packageExtras) : nil
                        return (prepared, archive)
                    } catch {
                        try? FileManager.default.removeItem(at: prepared.directory)
                        throw error
                    }
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
                } else if let archive {
                    // The share sheet receives the one archive; the loose files
                    // stay in the same directory until the temporary cleanup.
                    prepared = PhotoExportRenderer.Prepared(directory: result.directory, images: result.images, files: [archive])
                } else if packageExtras.isEmpty { prepared = result }
                else {
                    // Separate files: the videos and the details note go into the
                    // same share sheet as the photos, straight from where they live.
                    prepared = PhotoExportRenderer.Prepared(directory: result.directory, images: result.images,
                                                            files: result.files + packageExtras.map(\.url))
                }
            } catch {
                if let output { try? FileManager.default.removeItem(at: output.directory) }
                self.error = error.localizedDescription
            }
        }
    }
}
