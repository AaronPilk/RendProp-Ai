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
        let listingID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let libraryID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let orgID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
        let selected = try JSONDecoder().decode(SelectedListingVideoDownload.self, from: Data("""
        {"listing_id":"\(listingID)","org_id":"\(orgID)","selected_library_org_id":"\(libraryID)",
        "composition_id":"44444444-4444-4444-8444-444444444444",
        "asset_id":"55555555-5555-4555-8555-555555555555","duration_s":8,
        "bytes":1024,"sha256":"\(String(repeating: "a", count: 64))",
        "download_url":"https://rendprop.com/private-media/opaque"}
        """.utf8))
        _ = try selected.checked(listingID: listingID, libraryID: libraryID,
                                 physicalOrgID: orgID, liveDuration: 8)
        do {
            _ = try selected.checked(listingID: UUID(), libraryID: libraryID,
                                     physicalOrgID: orgID, liveDuration: 8)
            fatalError("Another property's selected video was accepted")
        } catch { }
        do {
            _ = try selected.checked(listingID: listingID, libraryID: UUID(),
                                     physicalOrgID: orgID, liveDuration: 8)
            fatalError("Another library's selected video was accepted")
        } catch { }
        do {
            _ = try selected.checked(listingID: listingID, libraryID: libraryID,
                                     physicalOrgID: orgID, liveDuration: 9)
            fatalError("A changed website selection was accepted")
        } catch { }
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
        print("PublishedListingVideoState: response, scoped download and card-priority cases passed")
    }
}
