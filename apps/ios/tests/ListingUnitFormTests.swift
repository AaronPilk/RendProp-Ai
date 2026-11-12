import Foundation

// UI/location boundaries only. The runner compiles the actual address/form,
// Listing, Money and client-contact sources; it never calls a geocoder.
struct CLLocationCoordinate2D { var latitude: Double; var longitude: Double }
enum FileStore {
    static func url(fromRelativePath path: String) -> URL { URL(fileURLWithPath: "/isolated/\(path)") }
}

@main struct ListingUnitFormTests {
    static func main() throws {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message); count += 1
        }
        let addresses = ["100 Condo Way", "100 Condo Way, Pineville, NC 28134", " 100 Condo Way, Unit City, NC 28134 "]
        for address in addresses {
            for unit in ["4B", "#4B", "Unit 4B", " 4B "] {
                let joined = ListingUnitAddress.compose(address: address, unit: unit)
                let parts = ListingUnitAddress.split(joined)
                check(parts.address == address.trimmingCharacters(in: .whitespacesAndNewlines), "Keep the entire building/city/state address")
                check(parts.unit == "4B", "Normalize a conventional unit prefix")
                check(ListingUnitAddress.compose(address: joined, unit: "5C").contains(" #5C"), "Replace the old canonical unit")
                check(!ListingUnitAddress.compose(address: joined, unit: "5C").contains(" #4B"), "Never accumulate unit suffixes")
            }
        }
        for old in ["100 Condo Way Apt 4B, Unit City, NC", "100 Condo Way, Unit 4B, Pineville, NC", "#4 Condo Way, Pineville, NC"] {
            check(ListingUnitAddress.split(old).address == old, "Never guess older free-form addresses apart")
            check(ListingUnitAddress.split(old).unit.isEmpty, "Only a street-line # suffix is canonical")
        }

        var source = Listing(address: "100 Condo Way #4B, Pineville, NC 28134", beds: 3, baths: 2.5,
                             sqft: 1850, price: .dollars(425_000))
        source.serverID = UUID(); source.serverOrgID = UUID(); source.latitude = 35.1; source.longitude = -80.9
        source.shareSlug = "preserved-published-slug"; source.shareURL = "https://example.invalid/f/existing"
        source.mainPhotoRelPath = "Photos/original.jpg"; source.allowSearchIndexing = true
        source.details = ["yearBuilt": "1998", "allow_indexing": "true", "customFact": "Verified", "blank": " "]
        source.clientContact = .init(listingID: source.id, enabled: true, publicCard: .init(name: "Client"), recipientEmail: "private@example.invalid")
        source.clientContactDirty = false
        var form = ListingFormData(listing: source)
        check(form.unit == "4B" && form.address == "100 Condo Way, Pineville, NC 28134", "Edit separates unit without losing city/state")
        form.setSuggestedAddress("200 Correct Building Way, Pineville, NC 28134")
        check(form.unit == "4B", "Current-location/autocomplete cannot know or erase the entered unit")
        form.beds = 4; form.baths = 3; form.sqft = "2,100 sq ft"; form.priceDollars = "$499,000"
        var edited = source
        form.apply(to: &edited)
        check(edited.address == "200 Correct Building Way #4B, Pineville, NC 28134", "Saved address includes the unit")
        check(edited.beds == 4 && edited.baths == 3 && edited.sqft == 2100 && edited.price.cents == 49_900_000, "Editable published facts round-trip")
        check(edited.details?["yearBuilt"] == "1998" && edited.details?["customFact"] == "Verified", "Editing real estate must preserve lookup and publication metadata")
        check(edited.details?["blank"] == nil, "Discard only empty detail values")
        check(edited.allowSearchIndexing == true && edited.details?["allow_indexing"] == "true", "Retain the explicit indexing choice")
        check(edited.id == source.id && edited.serverID == source.serverID && edited.serverOrgID == source.serverOrgID, "Editing cannot retarget local/cloud identity")
        check(edited.latitude == source.latitude && edited.longitude == source.longitude && edited.shareSlug == source.shareSlug && edited.shareURL == source.shareURL, "Preserve coordinates and existing publication")
        check(edited.mainPhotoRelPath == source.mainPhotoRelPath && edited.clientContact == source.clientContact && edited.clientContactDirty == false, "Do not dirty another client's identity or replace the cover")
        let restored = try JSONDecoder().decode(Listing.self, from: JSONEncoder().encode(edited))
        check(restored == edited && ListingFormData(listing: restored).unit == "4B", "Existing snapshot coding preserves the unit with all metadata")
        form.unit = ""
        form.apply(to: &edited)
        check(edited.address == "200 Correct Building Way, Pineville, NC 28134", "A deliberate blank unit removes the unit on edit")
        form.setSuggestedAddress("300 Condo Way #8A, Pineville, NC 28134")
        check(form.unit == "8A" && form.address == "300 Condo Way, Pineville, NC 28134", "A suggestion with an explicit canonical unit wins")
        let created = form.makeListing(coordinate: .init(latitude: 35.2, longitude: -80.8))
        check(created.address == "300 Condo Way #8A, Pineville, NC 28134" && created.latitude == 35.2 && created.longitude == -80.8, "Creation uses the same address truth and coarse location")
        check(created.details?["yearBuilt"] == "1998", "Lookup metadata also survives initial creation")

        var venue = source; venue.spaceTypeRaw = SpaceType.venue.rawValue; venue.address = "Unit City Venue #4B"
        var venueForm = ListingFormData(listing: venue); venueForm.unit = "7C"; venueForm.tagline = "Event space"
        venueForm.apply(to: &venue)
        check(venue.address == "Unit City Venue #4B" && venueForm.unit == "7C", "Business names are never interpreted as apartment addresses")
        check(venue.beds == 0 && venue.baths == 0 && venue.sqft == 0 && venue.price.cents == 0 && venue.tagline == "Event space", "Existing business-field behavior remains unchanged")
        print("PASSED: \(count) unit/address and metadata preservation assertions; no GPS/camera/network")
    }
}
