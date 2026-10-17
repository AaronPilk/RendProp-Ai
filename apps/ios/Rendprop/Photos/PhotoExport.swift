import SwiftUI
import UIKit
import Photos
import ImageIO
import UniformTypeIdentifiers

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
        var notes: [String] = []
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

    /// Retained files may contain PNG or HEIC bytes under a legacy .jpg name.
    /// Read once, identify the actual format, and keep those exact bytes.
    private static func retainedImage(at source: URL, read: (URL) throws -> Data) throws -> (data: Data, ext: String) {
        let data: Data
        do { data = try read(source) }
        catch { throw Failure(message: "A retained photo is missing or unreadable: \(source.lastPathComponent). Nothing was exported. Restore it or export only the current photo.") }
        guard let image = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(image) > 0, let type = CGImageSourceGetType(image),
              let ext = UTType(type as String)?.preferredFilenameExtension else {
            throw Failure(message: "Couldn't identify the retained photo's image format: \(source.lastPathComponent). Nothing was exported.")
        }
        return (data, ext == "jpeg" ? "jpg" : ext)
    }

    static func prepare(_ photos: [EnhancedPhoto], options: Options,
                        readRetained: (URL) throws -> Data = { try Data(contentsOf: $0) }) throws -> Prepared {
        guard !photos.isEmpty else { throw Failure(message: "There are no photos to export.") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Rendprop-photos-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            var urls: [URL] = []
            var deliveryFiles: [URL] = []
            let numberWidth = max(2, String(photos.count).count)
            for (offset, photo) in photos.enumerated() {
                let url = try autoreleasepool {
                    let photoDirectory = photo.enhancedURL.deletingLastPathComponent()
                    let history = try PhotoVersionHistory.load(directory: photoDirectory)
                    let number = String(format: "%0*d", numberWidth, offset + 1)
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
                    let originalData = options.original ? try retainedImage(at: source, read: readRetained) : nil
                    let ext = originalData?.ext ?? "jpg"
                    let target = directory.appendingPathComponent(number + "-\(suffix).\(ext)")
                    if options.original {
                        // Exact retained bytes. Ratio controls never apply to originals.
                        try originalData!.data.write(to: target, options: .atomic)
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
                        let captionURL = directory.appendingPathComponent(number + "-disclosure.txt")
                        let framingNote = options.levelDegrees == 0 ? "" : "\nExport copy manually leveled and cropped. The stored source is unchanged."
                        var withheldNote = ""
                        if options.includeOriginals, version?.originalVerified == true,
                           photo.originalURL.standardizedFileURL != photo.enhancedURL.standardizedFileURL {
                            try PhotoVersionHistory.requireDownloadReview(imageURL: photo.originalURL)
                            let retained = try retainedImage(at: photo.originalURL, read: readRetained)
                            let originalURL = directory.appendingPathComponent(number + "-retained-original." + retained.ext)
                            try retained.data.write(to: originalURL, options: .atomic)
                            urls.append(originalURL); deliveryFiles.append(originalURL)
                        }
                        // Build 61 — every saved version the app holds for this
                        // photo, alongside the rendered gallery delivery copy and
                        // its untouched
                        // original: the enhancement made before any AI edit,
                        // each earlier AI edit, a superseded staging ("it needs
                        // to be EVERY image associated and labeled" — Aaron,
                        // TestFlight 60). Oldest first, numbered by position in
                        // the photo's history, named by what each one is, exact
                        // stored bytes, each with its own disclosure note. The
                        // rendered gallery copy keeps '-edited'. A custom output that
                        // was never reviewed is withheld exactly as it is from a
                        // direct download, and the photo's note says so.
                        if options.includeOriginals, let version {
                            let savedVersions = history.history(for: version.id)
                                .sorted { $0.createdAt != $1.createdAt ? $0.createdAt < $1.createdAt : $0.id < $1.id }
                            let versionWidth = max(1, String(savedVersions.count).count)
                            var withheld = 0
                            for (position, other) in savedVersions.enumerated() {
                                let stored = photoDirectory.appendingPathComponent(other.imageFile)
                                if other.needsCustomReview { withheld += 1; continue }
                                try PhotoVersionHistory.requireDownloadReview(imageURL: stored)
                                let retained = try retainedImage(at: stored, read: readRetained)
                                let stem = number + "-version-" + String(format: "%0*d", versionWidth, position + 1) + "-" + other.exportSlug
                                let copy = directory.appendingPathComponent(stem + "." + retained.ext)
                                try retained.data.write(to: copy, options: .atomic)
                                let note = directory.appendingPathComponent(stem + "-disclosure.txt")
                                try Data((other.title + ".\n" + other.caption + "\nCheck your MLS or advertising platform's disclosure and original-photo rules.\n").utf8)
                                    .write(to: note, options: .atomic)
                                urls.append(copy); deliveryFiles.append(copy); deliveryFiles.append(note)
                            }
                            if withheld > 0 {
                                withheldNote = "\n\(withheld) saved version\(withheld == 1 ? " of this photo was" : "s of this photo were") not included: custom edits have not yet been reviewed. Compare each withheld edit with its source in Versions before downloading it."
                            }
                        }
                        try Data((caption + framingNote + withheldNote + "\nCheck your MLS or advertising platform's disclosure and original-photo rules.\n").utf8)
                            .write(to: captionURL, options: .atomic)
                        deliveryFiles.append(captionURL)
                    }
                    // Never deliver files from one history with captions or
                    // review permission taken from another in-flight history.
                    try PhotoVersionHistory.requireUnchanged(history, directory: photoDirectory)
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

    /// The coordinator package is deliberately separate from ordinary photo
    /// export. Masters keep exact saved bytes; upload copies are center crops
    /// at available resolution, without borders, overlays or invented detail.
    static func coordinatorSelectionNotes(_ photos: [EnhancedPhoto]) throws -> [String] {
        var notes: [String] = []
        for (offset, photo) in photos.enumerated() {
            let history = try PhotoVersionHistory.load(directory: photo.enhancedURL.deletingLastPathComponent())
            if let named = history.versions[photo.id], named.imageFile != photo.enhancedURL.lastPathComponent {
                throw PhotoVersionHistory.Failure.changedVersion
            }
            guard let selected = history.versions.values.first(where: { $0.imageFile == photo.enhancedURL.lastPathComponent }) else {
                throw PhotoVersionHistory.Failure.invalidHistory
            }
            let saved = history.history(for: selected.id).sorted {
                $0.createdAt != $1.createdAt ? $0.createdAt < $1.createdAt : $0.id < $1.id
            }
            let withheld = saved.filter(\.needsCustomReview)
            if !withheld.isEmpty {
                notes.append("Photo \(offset + 1): \(withheld.count) unreviewed custom version(s) withheld: " + withheld.map { "\($0.id) [\($0.imageFile)]" }.joined(separator: ", ") + ".")
            }
            let publication = history.publicationChoice(for: selected.id)
            notes.append("Photo \(offset + 1): latest in Photo Studio is \(selected.id) [\(selected.imageFile)]. Listing selection: " + (publication.map { "\($0.id) [\($0.imageFile)] (\($0.title))." } ?? "none recorded."))
            if selected.needsCustomReview { notes.append("Photo \(offset + 1): latest Photo Studio preview is withheld pending custom-edit review; it is not an approved selected-version fallback.") }
            let previews = saved.filter { !$0.needsCustomReview && $0.needsStagingReview }
            if !previews.isEmpty { notes.append("Photo \(offset + 1): \(previews.count) staging preview(s) retained in StagingPreviews only; review is not recorded and no platform copies are included: " + previews.map { "\($0.id) [\($0.imageFile)]" }.joined(separator: ", ") + ".") }
        }
        return notes
    }

    static func prepareCoordinator(_ photos: [EnhancedPhoto],
                                   readRetained: (URL) throws -> Data = { try Data(contentsOf: $0) }) throws -> Prepared {
        let empty = try prepareEmpty()
        let directory = empty.directory
        do {
            var files: [URL] = [], images: [URL] = []
            var notes = try coordinatorSelectionNotes(photos)
            var families = Set<String>()
            func write(_ data: Data, _ path: String) throws -> URL {
                guard coordinatorPathIsSafe(path) else { throw Failure(message: "An export filename is invalid. Nothing was exported.") }
                let url = directory.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                files.append(url)
                return url
            }
            for (offset, photo) in photos.enumerated() {
                try autoreleasepool {
                    let photoDirectory = photo.enhancedURL.deletingLastPathComponent()
                    let history = try PhotoVersionHistory.load(directory: photoDirectory)
                    if let named = history.versions[photo.id], named.imageFile != photo.enhancedURL.lastPathComponent {
                        throw PhotoVersionHistory.Failure.changedVersion
                    }
                    guard let selected = history.versions.values.first(where: { $0.imageFile == photo.enhancedURL.lastPathComponent }) else {
                        throw PhotoVersionHistory.Failure.invalidHistory
                    }
                    // One family may appear more than once in an old gallery.
                    // Preserve one complete history rather than duplicate paths.
                    let familyKey = photoDirectory.standardizedFileURL.path + "/" + selected.familyID
                    guard !history.hiddenFamilies.contains(selected.familyID) else { throw PhotoVersionHistory.Failure.changedVersion }
                    guard families.insert(familyKey).inserted else { return }
                    let number = String(format: "%02d", offset + 1)
                    let saved = history.history(for: selected.id).sorted {
                        $0.createdAt != $1.createdAt ? $0.createdAt < $1.createdAt : $0.id < $1.id
                    }
                    let publication = history.publicationChoice(for: selected.id)
                    let versionWidth = max(2, String(saved.count).count)
                    if let originalFile = selected.originalFile, selected.originalVerified {
                        let source = photoDirectory.appendingPathComponent(originalFile)
                        try PhotoVersionHistory.requireDownloadReview(imageURL: source)
                        let retained = try retainedImage(at: source, read: readRetained)
                        _ = try write(retained.data, "Originals/" + number + "-retained-original." + retained.ext)
                    } else if photo.originalURL.standardizedFileURL != photo.enhancedURL.standardizedFileURL {
                        try PhotoVersionHistory.requireDownloadReview(imageURL: photo.originalURL)
                        let retained = try retainedImage(at: photo.originalURL, read: readRetained)
                        _ = try write(retained.data, "EarlierSources/" + number + "-source-unverified." + retained.ext)
                        notes.append("Photo \(offset + 1): earlier source history is unverified; it is in EarlierSources, not Originals.")
                    }
                    for (position, version) in saved.enumerated() {
                        // Custom review is an exact persisted file permission,
                        // including descendants. Export never marks it reviewed.
                        if version.needsCustomReview { continue }
                        try autoreleasepool {
                        let source = photoDirectory.appendingPathComponent(version.imageFile)
                        try PhotoVersionHistory.requireDownloadReview(imageURL: source)
                        let retained = try retainedImage(at: source, read: readRetained)
                        guard let image = UIImage(data: retained.data) else { throw Failure(message: "Couldn't decode a saved photo version. Nothing was exported.") }
                        let category = version.needsStagingReview ? "StagingPreviews" : version.effects.contains("stage") ? "Staged"
                            : (version.effects.contains("declutter") ? "Decluttered" : (version.effects.isEmpty ? "Enhanced" : "Edited"))
                        let stem = number + "-version-" + String(format: "%0*d", versionWidth, position + 1) + "-" + version.exportSlug
                        let master = try write(retained.data, category + "/" + stem + "." + retained.ext)
                        images.append(master)
                        let selectedNote = publication?.id == version.id ? "Selected for listing."
                            : (selected.id == version.id ? "Latest in Photo Studio; not selected for listing." : "Other saved version; not selected for listing.")
                        let reviewNote = version.needsStagingReview ? "\nSTAGING PREVIEW — review is not recorded. Not approved for publication; no platform copies are included." : ""
                        let disclosure = version.title + ".\n" + version.caption + "\n" + selectedNote
                            + reviewNote
                            + "\nSaved version ID: " + version.id + "; source file: " + version.imageFile + ".\nMaster file: exact saved bytes, unchanged format and full available dimensions.\nCheck your MLS or advertising platform's original-photo and disclosure requirements before publishing.\n"
                        _ = try write(Data(disclosure.utf8), category + "/" + stem + "-disclosure.txt")
                        // Keep the pending preview as a clearly named master,
                        // never as an upload-ready copy or an implicit approval.
                        if version.needsStagingReview { return }
                        for (platform, aspect) in [("MLS", PhotoExportLayout.Aspect.landscape), ("Zillow", .landscape),
                                                   ("Instagram/Feed4x5", .feed), ("Instagram/Stories9x16", .portrait)] {
                            let cropped = render(image, aspect: aspect, framing: .crop, label: nil)
                            guard let encoded = cropped.jpegData(compressionQuality: 0.97), let pixels = cropped.cgImage else {
                                throw Failure(message: "Couldn't encode an upload photo. Nothing was exported.")
                            }
                            _ = try write(encoded, platform + "/" + category + "/" + stem + ".jpg")
                            let rotated = [.left, .right, .leftMirrored, .rightMirrored].contains(image.imageOrientation)
                            let sourceWidth = rotated ? image.cgImage!.height : image.cgImage!.width
                            let sourceHeight = rotated ? image.cgImage!.width : image.cgImage!.height
                            let resolution = "Available source: \(sourceWidth)×\(sourceHeight) pixels. Export: \(pixels.width)×\(pixels.height) pixels (\(aspect.rawValue))."
                            let cropNote = "Centered crop may remove content at the edges. No white borders, text overlay, enlargement or new detail. Originals and full saved masters are unchanged."
                            let warning = min(pixels.width, pixels.height) < 1080
                                ? " Limited available resolution: this copy's short edge is below 1080 pixels; check the destination's requirements. It was not upscaled." : ""
                            _ = try write(Data((disclosure + "\n" + resolution + "\n" + cropNote + warning + "\n").utf8), platform + "/" + category + "/" + stem + "-disclosure.txt")
                            notes.append(platform + "/" + category + "/" + stem + ".jpg — " + resolution + warning)
                        }
                        }
                    }
                    try PhotoVersionHistory.requireUnchanged(history, directory: photoDirectory)
                }
            }
            return Prepared(directory: directory, images: images, files: files, notes: notes)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    /// Explicit nested allowlist; file names remain leaf-only. The ZIP writer
    /// also rejects traversal and duplicate entries before writing anything.
    static func coordinatorPathIsSafe(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let masters = Set(["Originals", "Decluttered", "Staged", "StagingPreviews", "Enhanced", "Edited", "EarlierSources"])
        let platforms = Set(["MLS", "Zillow"])
        let validFolder = parts.count == 2 && (masters.contains(parts[0]) || ["Videos", "Attachments"].contains(parts[0]))
            || parts.count == 3 && platforms.contains(parts[0]) && masters.contains(parts[1]) && !["Originals", "EarlierSources", "StagingPreviews"].contains(parts[1])
            || parts.count == 4 && parts[0] == "Instagram" && ["Feed4x5", "Stories9x16"].contains(parts[1])
                && masters.contains(parts[2]) && !["Originals", "EarlierSources", "StagingPreviews"].contains(parts[2])
        guard validFolder, let leaf = parts.last, !leaf.isEmpty, leaf != ".", leaf != "..", !leaf.contains("\\"), !leaf.contains(":"), !leaf.contains("\0") else { return false }
        return ZipArchive.safeFileName(leaf, fallback: "") == leaf
    }

    static func packageCoordinator(_ prepared: Prepared, archiveName: String, extras: [Extra] = [], now: Date = Date()) throws -> URL {
        guard !prepared.files.isEmpty || !extras.isEmpty else { throw Failure(message: "There are no files to package.") }
        let title = ZipArchive.safeFileName(archiveName, fallback: "Rendprop")
        var readme = "\(title)\nRendprop coordinator handoff package. Only files saved on this iPhone are included; cloud-only media is not fetched.\n\nMasters: Originals contains the source files retained by Rendprop. New library imports preserve the file bytes and format supplied by Photos before enhancement. Camera captures and older library imports retain full-resolution JPEG copies made before enhancement, with camera metadata not preserved. Decluttered and Staged contain every eligible saved version separately. Enhanced, Edited and EarlierSources retain other saved sources. Masters are exact saved bytes in their real format, without cropping or re-encoding. Imported sources may contain edits made before Rendprop. Only files saved on this iPhone are included; cloud-only photos, tours and videos are not downloaded for this package.\n\nDelivery aspect presets, not platform rules: the MLS and Zillow folders use landscape 4:3; Instagram/Feed4x5 uses portrait 4:5; Instagram/Stories9x16 uses portrait 9:16. Each platform separates Decluttered, Staged, Enhanced and Edited versions. Copies are clean JPEGs encoded at quality 0.97, center-cropped at full available resolution without borders or upscaling. Cropping removes edges; review the master before uploading. No resolution or detail is invented. A short edge below 1080 pixels is flagged as limited available resolution, not a platform eligibility guarantee.\n\nThe same photo/version number maps a master to its platform copies and individual disclosure notes. All eligible saved predecessors stay accessible. Unreviewed custom edits and their unreviewed descendants are withheld. StagingPreviews contains pending staging masters, explicitly not approved for publication, with no platform copies. No export grants approval. This package is a handoff, not an automatic publication. Add each matching disclosure in your MLS/advertising platform and check its rules.\n\n"
        readme += prepared.notes.joined(separator: "\n") + "\n"
        let base = prepared.directory.standardizedFileURL.path + "/"
        var entries: [ZipArchive.Entry] = [], used = Set<String>()
        for file in prepared.files {
            guard file.standardizedFileURL.path.hasPrefix(base) else { throw Failure(message: "An export file is outside its prepared package.") }
            let name = String(file.standardizedFileURL.path.dropFirst(base.count))
            guard coordinatorPathIsSafe(name), used.insert(name.lowercased()).inserted else { throw Failure(message: "An export filename is invalid or duplicated.") }
            entries.append(ZipArchive.Entry(name: name, url: file))
        }
        for extra in extras {
            let ext = extra.url.pathExtension.lowercased()
            let folder = ["mp4", "mov", "m4v"].contains(ext) ? "Videos" : "Attachments"
            let safe = ZipArchive.safeFileName(extra.name, fallback: "file")
            var name = folder + "/" + safe, attempt = 1
            while used.contains(name.lowercased()) {
                attempt += 1
                let leaf = safe as NSString
                name = folder + "/" + leaf.deletingPathExtension + "-\(attempt)" + (leaf.pathExtension.isEmpty ? "" : "." + leaf.pathExtension)
            }
            guard coordinatorPathIsSafe(name) else { throw Failure(message: "A listing file name is invalid.") }
            used.insert(name.lowercased()); entries.append(ZipArchive.Entry(name: name, url: extra.url))
            readme += "\n" + name + " — " + extra.note
        }
        readme += "\n\nVideos are unchanged saved files. AI-generated motion must be disclosed wherever published; a still-photo fallback uses one cover-cropped photo and preserves the photographed geometry within that crop but does not establish unseen room connections. Listing details and other attachments are saved separately.\n"
        let note = prepared.directory.appendingPathComponent("README.txt")
        try Data(readme.utf8).write(to: note, options: .atomic)
        entries.insert(ZipArchive.Entry(name: "README.txt", url: note), at: 0)
        let archive = prepared.directory.appendingPathComponent(title + " listing.zip")
        try ZipArchive.write(entries, to: archive, modified: now)
        return archive
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
        if originalCount > 0 { readme += ", \(originalCount) retained original\(originalCount == 1 ? "" : "s") (same number, '-retained-original': the pre-enhancement source retained by Rendprop; new imports are JPEG copies without original camera metadata)" }
        if versionCount > 0 { readme += ", \(versionCount) saved version\(versionCount == 1 ? "" : "s") (same number, '-version-<n>-<what it is>', exact stored bytes in the order they were made)" }
        if disclosureCount > 0 { readme += ", \(disclosureCount) disclosure note\(disclosureCount == 1 ? "" : "s") (same name as the image, '-disclosure.txt')" }
        if whole { readme += ", \(extras.count) more file\(extras.count == 1 ? "" : "s") listed below" }
        readme += ".\n\n"
        if versionCount > 0 {
            readme += "The package includes retained originals where verified, available saved enhancements and AI edits in the order they were made, and the version shown in the app. '-edited.jpg' is a rendered delivery copy; the matching stored version is also included among '-version-' files without changing its bytes. Unreviewed custom edits are withheld; each photo's disclosure note reports any withheld versions. "
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
    let coordinatorPackage: Bool
    private let canExport: () -> Bool
    /// Told after files were saved to Photos or handed to the share sheet:
    /// the photos, whether only their originals/sources were exported, and
    /// whether it was a whole-listing package. Observes; never gates.
    private let onExported: @MainActor (_ photos: [EnhancedPhoto], _ originalsOnly: Bool, _ listingPackage: Bool) -> Void
    init(photos: [EnhancedPhoto], original: Bool = false, includeOriginals: Bool = true,
         archiveName: String = "Rendprop", extras: [PhotoExportRenderer.Extra] = [], coordinatorPackage: Bool = false,
         canExport: @escaping () -> Bool = { true },
         onExported: @escaping @MainActor (_ photos: [EnhancedPhoto], _ originalsOnly: Bool, _ listingPackage: Bool) -> Void = { _, _, _ in }) {
        self.photos = photos
        self.archiveName = archiveName
        self.extras = extras
        self.coordinatorPackage = coordinatorPackage
        self.canExport = canExport
        self.onExported = onExported
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
    @State private var packageNotes: [String] = []
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
            Group {
                if coordinatorPackage {
                    coordinatorPackageContent
                } else {
                    photoExportForm
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
            .task(id: previewKey) {
                if coordinatorPackage {
                    do { packageNotes = try PhotoExportRenderer.coordinatorSelectionNotes(photos) }
                    catch { self.error = error.localizedDescription }
                } else { await updatePreview() }
            }
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

    private var photoExportForm: some View {
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
                        Toggle("Include retained originals and every saved version", isOn: $includeOriginals)
                        Text("Verified retained originals and every saved version keep their exact bytes and original format, which may be HEIC or PNG. The current JPEG delivery copy is included too. Unreviewed custom edits are withheld. Turn this off for current JPEG copies only. Imported sources may contain edits made before Rendprop.")
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
                            ? "One ZIP with eligible photo versions, videos and listing details saved on this iPhone, plus disclosure notes and a README. Cloud-only files are not included. It opens on any Mac, PC or phone."
                            : "One ZIP with eligible saved photo versions, their disclosure notes and a README. Unreviewed custom edits are withheld. It opens on any Mac, PC or phone.")
                         : (wholeListing
                            ? "Eligible photos, retained sources, disclosure notes, videos and listing details saved on this iPhone are shared as separate files. Cloud-only files are not included. Better for AirDrop to another iPhone."
                            : "Each photo, original, other version and disclosure note is shared as its own file. Better for AirDrop to another iPhone."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                Button { start(saveToPhotos: false) } label: {
                    Label(coordinatorPackage || asArchive && canArchive ? "Share one ZIP file" : (wholeListing ? "Share all files · Save to Files" : (original ? "Share or save source files" : "Download JPEGs · Share or save to Files")),
                          systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("export.share")
                if !coordinatorPackage && !photos.isEmpty {
                    Button { start(saveToPhotos: true) } label: { Label("Save to Photos", systemImage: "square.and.arrow.down") }
                }
                Text(coordinatorPackage ? "Send this ZIP to your coordinator, office or client. Stored listing files stay unchanged." : asArchive && canArchive
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
    }

    private var coordinatorPackageContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "shippingbox.fill")
                        .font(.title2)
                        .foregroundStyle(Theme.accent)
                        .frame(width: 44, height: 44)
                        .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Listing package").font(.headline).foregroundStyle(Theme.ink)
                        if !archiveName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           archiveName != "Rendprop" {
                            Text(archiveName).font(.subheadline).foregroundStyle(Theme.inkDim)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text("One organized ZIP of files saved on this iPhone.")
                            .font(.footnote).foregroundStyle(Theme.inkDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()

                VStack(alignment: .leading, spacing: 16) {
                    Text("What's included").font(.headline).foregroundStyle(Theme.ink)
                        .accessibilityIdentifier("export.coordinatorFolders")
                    if !photos.isEmpty {
                        coordinatorMaterial("Photos & saved versions", "Originals and eligible saved edits", icon: "photo.stack")
                        coordinatorMaterial("Listing & social copies", "MLS, Zillow and Instagram presets", icon: "rectangle.on.rectangle")
                    }
                    if !extras.isEmpty {
                        coordinatorMaterial("Saved listing files", "\(extras.count) additional file\(extras.count == 1 ? "" : "s")", icon: "folder")
                    }
                    coordinatorMaterial("Disclosure notes", "README and recorded edit information", icon: "doc.text")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()

                Text("Originals stay unchanged. Delivery copies crop edges; review edits before publishing.")
                .font(.footnote).foregroundStyle(Theme.inkDim)
                .fixedSize(horizontal: false, vertical: true)

                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Every eligible saved photo version stays separate. Full saved masters and retained sources keep their stored bytes. Delivery aspect presets use centered crops: MLS/Zillow folders 4:3, Instagram feed 4:5, stories 9:16. These are presets, not platform rules. Pending staging has no platform copies.")
                        Text("The README and matching text files name each edit, disclose cropping and report actual pixel dimensions. Low-resolution sources are flagged. Check the photos and your platform's rules before publishing.")
                        Text("Pending staging is preview-only, with no listing or social copies. Unreviewed custom edits are withheld.")
                    }
                    .font(.footnote).foregroundStyle(Theme.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                } label: {
                    Text("Formats & disclosures").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                }
                .tint(Theme.accent)
                .accessibilityIdentifier("export.formatsDetails")
                .card()

                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 12) {
                        if !extras.isEmpty {
                            Text(extras.map(\.name).joined(separator: "\n"))
                                .textSelection(.enabled)
                                .accessibilityIdentifier("export.packageExtras")
                        }
                        ForEach(packageNotes, id: \.self) { Text($0).textSelection(.enabled) }
                    }
                    .font(.footnote).foregroundStyle(Theme.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                } label: {
                    Text("Files & review notes").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                }
                .tint(Theme.accent)
                .accessibilityIdentifier("export.fileDetails")
                .card()
            }
            .padding(Theme.spacing)
        }
        .background(Theme.bg)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 8) {
                if let error {
                    Text(error).font(.footnote).foregroundStyle(Theme.bad)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if working { ProgressView("Preparing listing package…").font(.footnote) }
                PrimaryButton(title: "Share ZIP", systemImage: "square.and.arrow.up", isDisabled: working, isCompact: true) {
                    start(saveToPhotos: false)
                }
                .accessibilityIdentifier("export.share")
            }
            .padding(.horizontal, Theme.spacing).padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(Theme.bg)
            .overlay(alignment: .top) { Divider() }
        }
    }

    private func coordinatorMaterial(_ title: String, _ detail: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundStyle(Theme.accent)
                .frame(width: 24).frame(minHeight: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                Text(detail).font(.footnote).foregroundStyle(Theme.inkDim)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
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
        let wantsArchive = (coordinatorPackage || asArchive && canArchive) && !saveToPhotos
        let coordinator = coordinatorPackage
        let archiveTitle = archiveName
        let packageExtras = saveToPhotos ? [] : extras
        Task { @MainActor in
            defer { working = false }
            var output: PhotoExportRenderer.Prepared?
            do {
                let input = photos
                let (result, archive) = try await Task.detached(priority: .userInitiated) { () -> (PhotoExportRenderer.Prepared, URL?) in
                    let prepared = coordinator ? try PhotoExportRenderer.prepareCoordinator(input) : (input.isEmpty ? try PhotoExportRenderer.prepareEmpty() : try PhotoExportRenderer.prepare(input, options: options))
                    do {
                        let archive = wantsArchive ? (coordinator ? try PhotoExportRenderer.packageCoordinator(prepared, archiveName: archiveTitle, extras: packageExtras) : try PhotoExportRenderer.package(prepared, archiveName: archiveTitle, extras: packageExtras)) : nil
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
                if currentContext { onExported(input, options.original, coordinator || !packageExtras.isEmpty) }
            } catch {
                if let output { try? FileManager.default.removeItem(at: output.directory) }
                self.error = error.localizedDescription
            }
        }
    }
}
