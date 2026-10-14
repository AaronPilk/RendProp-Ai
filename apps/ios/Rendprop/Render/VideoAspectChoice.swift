import Foundation

/// One purpose determines both the generated request and the delivered canvas.
/// Saved reel records already persist their aspect; older records stay portrait.
enum VideoAspectChoice: String, CaseIterable, Codable, Sendable {
    case socialMedia = "social_media"
    case listing

    var title: String { self == .socialMedia ? "Social media" : "Listing" }
    var portrait: Bool { self == .socialMedia }
    var aspect: String { portrait ? "9:16" : "16:9" }
    var width: Int { portrait ? 1080 : 1920 }
    var height: Int { portrait ? 1920 : 1080 }
    var formatDescription: String { portrait ? "Vertical · 9:16 · 1080 × 1920" : "Landscape · 16:9 · 1920 × 1080" }
    var explanation: String {
        portrait ? "For Instagram Reels, TikTok and vertical posts." : "For your property website and a landscape listing video."
    }
    init(portrait: Bool) { self = portrait ? .socialMedia : .listing }
    static func saved(aspect: String?) -> Self { aspect == "16:9" ? .listing : .socialMedia }
}

/// Bounds a serial photo-video recipe without silently cutting its selection.
/// Five-second provider clips are still requested one at a time.
enum VideoSelectionCapacity {
    static let maximumPhotos = 100
    static let maximumClips = 101 // the selected photos plus one opening clip
    static let maximumPlannerPhotos = 20
    static let maximumPreparedJPEGBytes = 8 * 1024 * 1024
    static let maximumPreparedBase64Bytes = 128 * 1024 * 1024
    static let maximumRecipeBytes = 256 * 1024 * 1024
    static var maximumPhotoBase64Bytes: Int { ((maximumPreparedJPEGBytes + 2) / 3) * 4 }
    static func canCreate(photoCount: Int, totalCount: Int) -> Bool {
        photoCount >= 0 && photoCount <= maximumPhotos && totalCount >= 2 && totalCount <= maximumClips
    }
}
