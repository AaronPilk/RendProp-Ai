import Foundation
import ImageIO
import UIKit

/// App-container paths + free-space checks + per-listing cleanup.
enum FileStore {
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var caches: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }

    static var recordingsDir: URL { subdir("Recordings") }
    static var importsDir: URL { subdir("Imports") }
    /// Generated aerial clips: `Aerials/<listingID>-<unixstamp>.mp4` (decision A1).
    static var aerialsDir: URL { subdir("Aerials") }

    private static func subdir(_ name: String) -> URL {
        let url = documents.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func newRecordingURL() -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return recordingsDir.appendingPathComponent("walkthrough-\(stamp).mov")
    }

    /// Path of `url` relative to Documents (e.g. "Recordings/tour-ab12.mp4").
    /// Persist THIS, never the absolute path — iOS can change the container base
    /// between launches/reinstalls. Falls back to the last path component.
    static func relativePath(for url: URL) -> String {
        let base = documents.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path.hasPrefix(base) {
            let trimmed = String(path.dropFirst(base.count)).drop(while: { $0 == "/" })
            return String(trimmed)
        }
        return url.lastPathComponent
    }

    /// Rebuild an absolute URL from a Documents-relative path.
    static func url(fromRelativePath rel: String) -> URL {
        documents.appendingPathComponent(rel)
    }

    static func fileSize(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64).flatMap { $0 } ?? 0
    }

    /// Free space available for "important" usage (what recording needs).
    static func freeSpaceBytes() -> Int64 {
        let values = try? documents.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return Int64(values?.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    /// 4K/60 ≈ ~400 MB/min. Pre-flight: is there room for `minutes` of capture?
    static func hasSpace(forMinutes minutes: Double) -> Bool {
        freeSpaceBytes() > Int64(minutes * 400_000_000) + 500_000_000 // + headroom
    }

    // MARK: - Per-listing cleanup (AppModel.remove)

    /// The `preview-<name>.html` PlayerWebView writes next to a video.
    static func previewHTMLURL(besideVideo url: URL) -> URL {
        url.deletingLastPathComponent()
            .appendingPathComponent("preview-\(url.deletingPathExtension().lastPathComponent).html")
    }

    /// Delete a video file plus its generated preview page (both best-effort).
    static func removeVideoAndPreview(_ url: URL?) {
        guard let url else { return }
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        try? fm.removeItem(at: previewHTMLURL(besideVideo: url))
    }

    /// Remove every file a listing produced: its recording/import + gyro sidecar,
    /// its rendered tour(s), `Photos/<id>`, `FloorPlans/<id>*`, `Aerials/<id>-*`,
    /// `reels/<id>-*`, legacy root-level `enhanced-<id>*` / `aerial-<id>*`, the
    /// standard render `Recordings/tour-<asset8>.mp4`, cached poster, and every
    /// `preview-*.html` beside those videos. All best-effort; never throws.
    static func deleteListingFiles(listingID id: UUID,
                                   assetURL: URL?,
                                   sidecarURL: URL?,
                                   assetID: UUID?,
                                   tourURL: URL?) {
        let fm = FileManager.default
        let idString = id.uuidString

        removeVideoAndPreview(assetURL)
        if let sidecarURL { try? fm.removeItem(at: sidecarURL) }
        removeVideoAndPreview(tourURL)
        if let assetID {
            // The on-device render (may differ from tourURL when an AI-enhanced
            // file replaced it as the playable tour).
            removeVideoAndPreview(recordingsDir.appendingPathComponent("tour-\(assetID.uuidString.prefix(8)).mp4"))
        }

        try? fm.removeItem(at: documents.appendingPathComponent("Photos/\(idString)", isDirectory: true))
        try? fm.removeItem(at: caches.appendingPathComponent("posters/poster-\(idString).jpg"))

        removeFiles(in: documents.appendingPathComponent("FloorPlans", isDirectory: true), withPrefix: idString)
        removeFiles(in: documents.appendingPathComponent("Aerials", isDirectory: true), withPrefix: "\(idString)-")
        removeFiles(in: documents.appendingPathComponent("reels", isDirectory: true), withPrefix: "\(idString)-")
        removeFiles(in: recordingsDir, withPrefix: "enhanced-\(idString)")
        removeFiles(in: recordingsDir, withPrefix: "preview-enhanced-\(idString)")
        // Legacy locations (files written by earlier builds at the Documents root).
        removeFiles(in: documents, withPrefix: "enhanced-\(idString)")
        removeFiles(in: documents, withPrefix: "aerial-\(idString)")
        removeFiles(in: documents, withPrefix: "preview-enhanced-\(idString)")
        removeFiles(in: documents, withPrefix: "preview-aerial-\(idString)")
    }

    /// Delete every regular file in `dir` whose name starts with `prefix`
    /// (case-insensitive). Missing directory → no-op.
    static func removeFiles(in dir: URL, withPrefix prefix: String) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        let needle = prefix.lowercased()
        for item in items where item.lastPathComponent.lowercased().hasPrefix(needle) {
            try? fm.removeItem(at: item)
        }
    }
}

// MARK: - Downsampled, cached image thumbnails
// Listing cards used to decode full-size hero JPEGs synchronously inside
// `body` (per card, per re-render). This decodes ONCE, off the main thread,
// at card resolution via ImageIO, and memoizes by path + modification date.
enum ImageThumbnails {
    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 200
        c.totalCostLimit = 64 * 1024 * 1024
        return c
    }()

    private static func key(_ url: URL, maxPixel: CGFloat) -> NSString {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
            .flatMap { $0 }?.timeIntervalSince1970 ?? 0
        return "\(url.path)|\(Int(mtime))|\(Int(maxPixel))" as NSString
    }

    /// Cached thumbnail if one was already decoded (synchronous, main-thread safe).
    static func cached(_ url: URL, maxPixel: CGFloat = 800) -> UIImage? {
        cache.object(forKey: key(url, maxPixel: maxPixel))
    }

    /// Decode (or fetch from cache) a thumbnail whose longest side is ≤ `maxPixel`.
    /// Runs the decode on a background task; returns nil if the file can't be read.
    static func load(_ url: URL, maxPixel: CGFloat = 800) async -> UIImage? {
        let k = key(url, maxPixel: maxPixel)
        if let hit = cache.object(forKey: k) { return hit }
        let decoded: UIImage? = await Task.detached(priority: .userInitiated) {
            ImageThumbnails.decode(url, maxPixel: maxPixel)
        }.value
        if let decoded {
            let cost = Int(decoded.size.width * decoded.size.height * decoded.scale * decoded.scale * 4)
            cache.setObject(decoded, forKey: k, cost: cost)
        }
        return decoded
    }

    /// Evict a path (call after overwriting an image so the next load re-decodes).
    static func invalidate(_ url: URL) {
        for px in [400, 800, 1200] as [CGFloat] {
            cache.removeObject(forKey: key(url, maxPixel: px))
        }
    }

    private static func decode(_ url: URL, maxPixel: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixel),
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}
