import Foundation

/// The public property's selected photo video is server-owned. A video saved in
/// this phone's reels directory does not establish what the website is showing.
struct PublishedListingVideoState: Decodable, Equatable {
    struct Video: Decodable, Equatable {
        let durationS: Double
        let brandingPolicy: String
        enum CodingKeys: String, CodingKey {
            case durationS = "duration_s", brandingPolicy = "branding_policy"
        }
    }

    let slug: String
    let listingVideo: Video?

    enum CodingKeys: String, CodingKey {
        case slug, listingVideo = "listing_video"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // An older or incomplete tour response cannot prove that no video is
        // selected. It must leave the card in an unknown state instead.
        guard values.contains(.listingVideo) else {
            throw DecodingError.keyNotFound(CodingKeys.listingVideo,
                .init(codingPath: values.codingPath, debugDescription: "Website video state is missing."))
        }
        slug = try values.decode(String.self, forKey: .slug)
        listingVideo = try values.decodeIfPresent(Video.self, forKey: .listingVideo)
    }

    static func checked(_ data: Data, slug expectedSlug: String) throws -> Self {
        guard expectedSlug.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil else {
            throw StateError.invalid
        }
        let state = try JSONDecoder().decode(Self.self, from: data)
        guard state.slug == expectedSlug,
              state.listingVideo.map({ $0.brandingPolicy == "unbranded" &&
                  $0.durationS.isFinite && $0.durationS > 0 && $0.durationS <= 600 }) ?? true else {
            throw StateError.invalid
        }
        return state
    }

    enum StateError: Error { case invalid }
}

protocol PublishedListingVideoReading {
    @MainActor func publishedListingVideo(slug: String) async throws -> PublishedListingVideoState
}

enum PublishedListingVideoStatus: Equatable {
    case unpublished, checking, live(Double), noPhotoVideo, unavailable

    func card(hasLocalSelection: Bool) -> ListingVideoCardContent {
        switch self {
        case .live(let duration): return .live(duration)
        case .checking: return hasLocalSelection ? .local : .checking
        case .unavailable: return hasLocalSelection ? .local : .unavailable
        case .unpublished, .noPhotoVideo: return hasLocalSelection ? .local : .start
        }
    }
}

enum ListingVideoCardContent: Equatable {
    case live(Double), local, checking, unavailable, start
}
