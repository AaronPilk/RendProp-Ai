import Foundation

@main struct PublishedListingVideoStateTests {
    static func main() throws {
        let slug = "sample-listing-1"
        func read(_ json: String) throws -> PublishedListingVideoState {
            try PublishedListingVideoState.checked(Data(json.utf8), slug: slug)
        }
        func rejects(_ json: String) {
            do {
                _ = try read(json)
                fatalError("An unverified website response was accepted")
            } catch { }
        }

        let live = try read("""
        {"slug":"\(slug)","listing_video":{"duration_s":8,"branding_policy":"unbranded"}}
        """)
        precondition(live.listingVideo?.durationS == 8)
        let empty = try read(#"{"slug":"\#(slug)","listing_video":null}"#)
        precondition(empty.listingVideo == nil)

        rejects(#"{"slug":"\#(slug)"}"#)
        rejects(#"{"slug":"other-listing","listing_video":null}"#)
        rejects(#"{"slug":"\#(slug)","listing_video":{"duration_s":0,"branding_policy":"unbranded"}}"#)
        rejects(#"{"slug":"\#(slug)","listing_video":{"duration_s":8,"branding_policy":"branded"}}"#)

        // An older saved reel must not hide a newer website selection.
        precondition(PublishedListingVideoStatus.live(8).card(hasLocalSelection: true) == .live(8))
        precondition(PublishedListingVideoStatus.live(8).card(hasLocalSelection: false) == .live(8))
        precondition(PublishedListingVideoStatus.noPhotoVideo.card(hasLocalSelection: true) == .local)
        precondition(PublishedListingVideoStatus.noPhotoVideo.card(hasLocalSelection: false) == .start)
        precondition(PublishedListingVideoStatus.checking.card(hasLocalSelection: false) == .checking)
        precondition(PublishedListingVideoStatus.unavailable.card(hasLocalSelection: false) == .unavailable)
        precondition(PublishedListingVideoStatus.unpublished.card(hasLocalSelection: true) == .local)
        print("PublishedListingVideoState: six response and seven card-priority cases passed")
    }
}
