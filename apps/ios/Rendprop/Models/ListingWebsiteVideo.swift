import Foundation

extension Listing {
    /// Snapshots retain only the path; immutable source metadata lives beside
    /// the finished MP4 and was written before its generation recipe retired.
    var websiteVideo: ListingVideoRecord? {
        get {
            guard let path = websiteVideoRelPath, !path.hasPrefix("/"), path.hasPrefix("reels/"),
                  !path.split(separator: "/").contains(".."),
                  let record = try? ListingVideoStore.load(for: FileStore.url(fromRelativePath: path)),
                  record.listingID == id, record.relativePath == path else { return nil }
            return record
        }
        set { websiteVideoRelPath = newValue?.relativePath }
    }
}
