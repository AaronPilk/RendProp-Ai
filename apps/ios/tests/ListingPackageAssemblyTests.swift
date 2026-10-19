// Closed package-assembly fixture. Production shareListingPackage and
// listingDetailsNote bodies are extracted unchanged by the companion runner.
import Foundation

// Real Foundation filesystem calls; only the note destination is injectable.
// A regular file as the destination directory forces a real ENOTDIR failure.
final class PackageFixtureFileManager {
    var temporaryDirectory = Foundation.FileManager.default.temporaryDirectory
    func fileExists(atPath path: String) -> Bool {
        Foundation.FileManager.default.fileExists(atPath: path)
    }
}
enum FileManager { static let `default` = PackageFixtureFileManager() }

struct Listing {
    var address = "400 Synthetic Package Lane"
    var tagline: String? = "  Synthetic listing description  "
    var cardChips = ["3 beds", "2 baths", "1,800 sqft"]
    var serverShareURL: URL? = URL(string: "https://example.invalid/f/fixture")
    var serverUnbrandedURL: URL? = URL(string: "https://example.invalid/mls/fixture")
    var soldAt: Date? = Date(timeIntervalSince1970: 1_700_000_000)
}
struct EnhancedPhoto {
    let id: String
    let originalURL: URL
    let enhancedURL: URL
}
struct LinearGradient {}
enum RPGradient {
    static let reel = LinearGradient(), aerial = LinearGradient(), photo = LinearGradient(), plan = LinearGradient()
}

// __ACTUAL_VALUE_TYPES__

@MainActor final class ListingPackageAssemblyHarness {
    var currentListing = Listing()
    var mediaItems: [ListingMediaItem] = []
    var admissionAllowed = true
    var admissionReads = 0
    var filePhotoExportAdmission: (() -> Bool)?
    var filePackageExtras: [PhotoExportRenderer.Extra] = []
    var filePhotoExport: PhotoExportSelection?
    var packageError: String?
    func mediaExportAdmission(for listing: Listing) -> () -> Bool {
        { self.admissionReads += 1; return self.admissionAllowed }
    }
    func run() { shareListingPackage() }

// __ACTUAL_ASSEMBLY_METHODS__
}

@main struct ListingPackageAssemblyTests {
    @MainActor static func main() throws {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message); checks += 1
        }
        let fm = Foundation.FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("synthetic-listing-package-\(UUID())", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let notes = root.appendingPathComponent("notes", isDirectory: true)
        try fm.createDirectory(at: notes, withIntermediateDirectories: true)
        FileManager.default.temporaryDirectory = notes
        var sourceBytes: [URL: Data] = [:]
        var items: [ListingMediaItem] = []
        func file(_ filename: String) throws -> URL {
            let url = root.appendingPathComponent(filename)
            let bytes = Data("original synthetic bytes for \(filename)".utf8)
            try bytes.write(to: url, options: .atomic)
            sourceBytes[url] = bytes
            return url
        }
        let original = try file("original-photo.jpg")
        let firstPhoto = try file("edited-photo.jpg")
        let secondPhoto = try file("photo-with-no-before.png")
        items.append(.init(id: "photo-edited-version", kind: .photo, url: firstPhoto,
            originalURL: original, createdAt: Date(timeIntervalSince1970: 20)))
        items.append(.init(id: "photo-original-only", kind: .photo, url: secondPhoto,
            originalURL: nil, createdAt: Date(timeIntervalSince1970: 10)))
        let kinds: [(ListingMediaItem.Kind, String)] = [(.tour, "mp4"), (.reel, "mov"),
            (.aerial, "mp4"), (.motionClip, "mp4"), (.floorPlan, "usdz")]
        for (kindIndex, entry) in kinds.enumerated() {
            for index in 0..<2 {
                let filename = "\(entry.0.rawValue)-\(index).\(entry.1)"
                items.append(.init(id: filename, kind: entry.0, url: try file(filename), originalURL: nil,
                    createdAt: Date(timeIntervalSince1970: Double(50 + kindIndex * 2 + index))))
            }
        }
        // Reverse video order to prove assembly applies createdAt before names.
        let rich = ListingPackageAssemblyHarness()
        rich.mediaItems = Array(items.reversed())
        rich.run()
        check(rich.packageError == nil, "rich package must prepare without error")
        check(rich.filePhotoExport != nil, "rich package must present the export selection")
        let photos = rich.filePhotoExport!.photos
        check(photos.count == 2, "all listing photos are selected")
        let edited = photos.first { $0.id == "edited-version" }
        check(edited?.originalURL == original && edited?.enhancedURL == firstPhoto,
            "edited photo keeps distinct original and current version")
        let unchanged = photos.first { $0.id == "original-only" }
        check(unchanged?.originalURL == secondPhoto && unchanged?.enhancedURL == secondPhoto,
            "a photo without a separate before uses its own source")
        let expectedNames = ["walkthrough-tour.mp4", "walkthrough-tour-2.mp4", "reel-01.mov", "reel-02.mov",
            "aerial-intro.mp4", "aerial-intro-2.mp4", "moving-photo-01.mp4", "moving-photo-02.mp4",
            "3d-floor-plan.usdz", "3d-floor-plan-2.usdz", "listing-details.txt"]
        check(rich.filePackageExtras.map(\.name) == expectedNames,
            "all video and scan kinds plus details get stable sequential names")
        check(rich.filePackageExtras.dropLast().map(\.url) == items.filter { $0.kind != .photo }.map(\.url),
            "every package extra references its exact original video or scan file")
        check(rich.filePackageExtras.prefix(2).map(\.url) == items.filter { $0.kind == .tour }.map(\.url),
            "walkthrough files retain their chronological order and source URLs")
        check(rich.filePackageExtras.first { $0.name == "aerial-intro.mp4" }!.note.contains("AI-generated"),
            "aerial description distinguishes generated footage")
        check(rich.filePackageExtras.first { $0.name == "moving-photo-01.mp4" }!.note.contains("AI-motion"),
            "moving photo description carries AI disclosure")
        let noteURL = rich.filePackageExtras.first { $0.name == "listing-details.txt" }!.url
        let note = try String(contentsOf: noteURL, encoding: .utf8)
        for expected in ["400 Synthetic Package Lane", "Synthetic listing description", "3 beds · 2 baths · 1,800 sqft",
                         "Listing page: https://example.invalid/f/fixture", "MLS-safe page (no branding): https://example.invalid/mls/fixture",
                         "Marked sold on", "Photos made or changed with AI carry their own disclosure notes"] {
            check(note.contains(expected), "listing details contains: \(expected)")
        }
        check(rich.filePhotoExportAdmission?() == true, "export carries the same current admission closure")
        rich.admissionAllowed = false
        check(rich.filePhotoExportAdmission?() == false, "export admission can refuse after account context changes")

        let missing = ListingPackageAssemblyHarness()
        missing.mediaItems = items
        let vanished = items.first { $0.kind == .tour }!.url
        try fm.removeItem(at: vanished)
        missing.run()
        check(missing.filePhotoExport == nil, "a missing cached video prevents package presentation")
        check(missing.filePackageExtras.isEmpty && missing.filePhotoExportAdmission == nil,
            "a missing source cannot leave partial export state")
        check(missing.packageError?.contains("no longer available") == true,
            "a missing cached video supplies an actionable package error")
        try sourceBytes[vanished]!.write(to: vanished, options: .atomic)

        let blocked = try file("not-a-directory")
        FileManager.default.temporaryDirectory = blocked
        let writeFailed = ListingPackageAssemblyHarness()
        writeFailed.mediaItems = items
        writeFailed.run()
        check(writeFailed.filePhotoExport == nil, "details write failure prevents package presentation")
        check(writeFailed.filePackageExtras.isEmpty && writeFailed.filePhotoExportAdmission == nil,
            "details write failure cannot leave partial export state")
        check(writeFailed.packageError?.contains("Free some space") == true,
            "details write failure supplies an actionable package error")
        FileManager.default.temporaryDirectory = notes

        let refused = ListingPackageAssemblyHarness()
        refused.mediaItems = items
        refused.admissionAllowed = false
        refused.run()
        check(refused.filePhotoExport == nil && refused.filePackageExtras.isEmpty && refused.filePhotoExportAdmission == nil,
            "refused admission prevents package presentation")
        check(refused.packageError == nil, "account refusal does not fabricate a media failure")
        let empty = ListingPackageAssemblyHarness()
        empty.run()
        check(empty.filePhotoExport == nil && empty.filePackageExtras.isEmpty && empty.packageError == nil,
            "an empty listing does not present a phantom details-only package")

        let videoOnly = ListingPackageAssemblyHarness()
        videoOnly.mediaItems = [items.first { $0.kind == .tour }!]
        videoOnly.run()
        check(videoOnly.filePhotoExport?.photos.isEmpty == true && videoOnly.filePackageExtras.count == 2,
            "a video-only listing offers its walkthrough and details without requiring photos")
        let photoOnly = ListingPackageAssemblyHarness()
        photoOnly.mediaItems = [items.first { $0.kind == .photo }!]
        photoOnly.run()
        check(photoOnly.filePhotoExport?.photos.count == 1 && photoOnly.filePackageExtras.map(\.name) == ["listing-details.txt"],
            "a photo-only listing offers its photo and details")
        for (url, before) in sourceBytes {
            let after = try Data(contentsOf: url)
            check(after == before, "package assembly leaves all original media bytes unchanged")
        }
        print("PASSED: \(checks) actual package assembly assertions; isolated Foundation filesystem only")
    }
}
