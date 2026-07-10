import Foundation

struct Listing: Identifiable, Codable, Hashable {
    enum Status: String, Codable, CaseIterable {
        case draft, uploading, processing, ready, expired
    }

    var id = UUID()
    var address: String
    var beds: Int
    var baths: Double
    var sqft: Int
    var price: Money
    var status: Status = .draft
    /// Seeded demo listings show sample stats; real listings never do.
    var isSample = false
    var createdAt = Date()
    /// Optional so listings saved before these fields existed still decode.
    var soldAt: Date? = nil
    var zillowURL: String? = nil
    /// The enhanced photo (path relative to Documents) shown as the card's hero
    /// and in the public app link.
    var mainPhotoRelPath: String? = nil
    /// Cached geocode of `address` so we don't re-hit the geocoder every open.
    var latitude: Double? = nil
    var longitude: Double? = nil
    /// Short description used by non-real-estate businesses in place of beds/baths
    /// (e.g. "Rooftop cocktail bar", "12,000 sq ft event hall").
    var tagline: String? = nil
    /// Industry-specific fields keyed by DetailField.key (e.g. cuisineType,
    /// membershipPrice, weeklySpecial). Optional/Codable-safe.
    var details: [String: String]? = nil

    func detail(_ key: String) -> String { details?[key] ?? "" }

    /// The primary deep-link action URL for this listing's business type
    /// (reservations, booking, online store, website), if the owner set one.
    var actionURL: URL? {
        guard let key = SpaceType.current.actionURLKey else { return nil }
        let raw = detail(key).trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return nil }
        return URL(string: raw.lowercased().hasPrefix("http") ? raw : "https://\(raw)")
    }

    var isSold: Bool { soldAt != nil }
    var hasCoordinate: Bool { latitude != nil && longitude != nil }

    var zillowURLValue: URL? {
        guard let z = zillowURL?.trimmingCharacters(in: .whitespaces), !z.isEmpty else { return nil }
        return URL(string: z.lowercased().hasPrefix("http") ? z : "https://\(z)")
    }

    /// Absolute URL of the main photo, if the file still exists.
    var mainPhotoURL: URL? {
        guard let p = mainPhotoRelPath else { return nil }
        let url = FileStore.url(fromRelativePath: p)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    var metaLine: String {
        let bathsText = baths.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(baths)) : String(baths)
        var parts = ["\(beds) bd", "\(bathsText) ba"]
        if sqft > 0 { parts.append("\(sqft.formatted()) sqft") }
        return parts.joined(separator: " · ")
    }

    /// The card/detail subtitle, adapted to the business type: property details
    /// for real estate, the free-text tagline for everyone else.
    var subtitleLine: String {
        SpaceType.current.showsPropertyDetails ? metaLine : (tagline ?? "")
    }
}

// MARK: - Business type
// Rendprop isn't real-estate-only: a venue, restaurant, bar, gym, or store can
// make a scroll-through tour too. The selected type adapts the app's wording,
// the capture area tags, and the tour's call-to-action. Defaults to real estate
// so existing users are unaffected.
enum SpaceType: String, CaseIterable, Identifiable {
    case realEstate = "real_estate"
    case venue
    case restaurant
    case retail
    case fitness
    case other

    var id: String { rawValue }

    static var current: SpaceType {
        SpaceType(rawValue: UserDefaults.standard.string(forKey: "space.type") ?? "") ?? .realEstate
    }

    var displayName: String {
        switch self {
        case .realEstate: return "Real estate"
        case .venue:      return "Event venue"
        case .restaurant: return "Restaurant / Bar"
        case .retail:     return "Retail / Grocery"
        case .fitness:    return "Gym / Studio"
        case .other:      return "Other business"
        }
    }

    var systemImage: String {
        switch self {
        case .realEstate: return "house.fill"
        case .venue:      return "party.popper.fill"
        case .restaurant: return "fork.knife"
        case .retail:     return "cart.fill"
        case .fitness:    return "dumbbell.fill"
        case .other:      return "building.2.fill"
        }
    }

    /// Lowercase singular noun for one space.
    var spaceNoun: String {
        switch self {
        case .realEstate: return "home"
        case .venue:      return "venue"
        case .restaurant: return "place"
        case .retail:     return "store"
        case .fitness:    return "studio"
        case .other:      return "space"
        }
    }
    var spaceNounCap: String { spaceNoun.prefix(1).uppercased() + spaceNoun.dropFirst() }

    var collectionTitle: String {
        switch self {
        case .realEstate: return "My Homes"
        case .venue:      return "My Venues"
        case .restaurant: return "My Places"
        case .retail:     return "My Stores"
        case .fitness:    return "My Studios"
        case .other:      return "My Spaces"
        }
    }

    var newItemTitle: String { "New \(spaceNounCap)" }

    /// Real estate shows beds/baths/sqft + price; others use a free-text tagline.
    var showsPropertyDetails: Bool { self == .realEstate }

    /// Label for the org field on the agent/owner card.
    var businessLabel: String { self == .realEstate ? "Brokerage" : "Business" }

    /// Tour end-card call-to-action.
    var ctaTitle: String {
        switch self {
        case .realEstate: return "Book a showing"
        case .venue:      return "Plan your event"
        case .restaurant: return "Book a table"
        case .retail:     return "Visit us"
        case .fitness:    return "Book a session"
        case .other:      return "Get in touch"
        }
    }

    /// Archive label + verb (real estate = "Sold").
    var archiveNoun: String { self == .realEstate ? "Sold" : "Archived" }
    var archiveVerb: String { self == .realEstate ? "sold" : "archived" }

    /// The details key whose URL the tour's primary CTA deep-links to
    /// (reservations / booking / online store / website). nil = use the lead form.
    var actionURLKey: String? {
        switch self {
        case .realEstate: return nil          // uses Zillow field instead
        case .venue:      return "bookingUrl"
        case .restaurant: return "reservationUrl"
        case .retail:     return "onlineStoreUrl"
        case .fitness:    return "bookingUrl"
        case .other:      return "website"
        }
    }

    /// Industry-specific owner input schema. Real estate keeps its dedicated
    /// beds/baths/sqft/price; every other type is data-driven from here.
    var detailFields: [DetailField] {
        switch self {
        case .realEstate:
            return []
        case .venue:
            return [
                DetailField("capacitySeated", "Max seated guests", .number),
                DetailField("capacityStanding", "Max standing", .number),
                DetailField("startingPrice", "Starting price", .price),
                DetailField("eventTypes", "Event types", .multiSelect(
                    ["Wedding", "Corporate", "Birthday", "Party", "Gala", "Conference", "Photo Shoot"])),
                DetailField("catering", "Catering", .singleSelect(
                    ["In-house", "In-house or outside", "Outside only", "None"])),
                DetailField("spaceSetting", "Indoor / Outdoor", .singleSelect(
                    ["Indoor", "Outdoor", "Both"])),
                DetailField("amenities", "Amenities", .multiSelect(
                    ["Tables & Chairs", "AV / Sound", "Stage", "Dance Floor", "Bridal Suite",
                     "Parking", "Wheelchair Accessible", "Kitchen", "WiFi", "Bar"])),
                DetailField("bookingUrl", "Booking / inquiry link", .url),
            ]
        case .restaurant:
            return [
                DetailField("cuisineType", "Cuisine", .multiSelect(
                    ["Italian", "Japanese", "Mexican", "American", "Steakhouse", "Seafood",
                     "Indian", "Thai", "Mediterranean", "French", "BBQ", "Vegan", "Cafe",
                     "Bar", "Cocktail Bar", "Wine Bar"])),
                DetailField("priceRange", "Price", .priceRange),
                DetailField("hours", "Hours", .hours),
                DetailField("reservationUrl", "Reservations link", .url),
                DetailField("menuUrl", "Menu link", .url),
                DetailField("amenities", "Features", .multiSelect(
                    ["Outdoor Seating", "Private Dining", "Live Music", "Happy Hour", "Full Bar",
                     "Takeout", "Delivery", "Wheelchair Accessible", "Parking", "Rooftop"])),
                DetailField("phone", "Phone", .text),
            ]
        case .retail:
            return [
                DetailField("storeCategory", "Store type", .singleSelect(
                    ["Grocery", "Convenience", "Specialty Food", "Bakery", "Liquor / Wine",
                     "Pharmacy", "Apparel", "Home & Hardware", "Boutique", "General Retail"])),
                DetailField("hours", "Hours", .hours),
                DetailField("phone", "Phone", .text),
                DetailField("onlineStoreUrl", "Online store / website", .url),
                DetailField("weeklySpecial", "Weekly special / promo", .multilineText),
                DetailField("shoppingOptions", "How to shop", .multiSelect(
                    ["In-store", "Curbside Pickup", "Local Delivery", "Online Order", "Ships Nationwide"])),
                DetailField("departments", "Departments", .multiSelect(
                    ["Produce", "Meat & Seafood", "Deli", "Bakery", "Dairy", "Frozen",
                     "Pantry", "Beverages", "Household", "Health & Beauty", "Floral"])),
            ]
        case .fitness:
            return [
                DetailField("facilityType", "Facility type", .singleSelect(
                    ["Gym", "Yoga Studio", "CrossFit", "Boutique / Classes", "Pilates", "Martial Arts"])),
                DetailField("membershipPrice", "Membership / mo", .price),
                DetailField("dayPassPrice", "Day pass", .price),
                DetailField("is247", "Open 24/7", .toggle),
                DetailField("hours", "Hours", .hours),
                DetailField("amenities", "Amenities", .multiSelect(
                    ["Showers", "Sauna", "Steam Room", "Childcare", "Parking", "Towel Service",
                     "Lockers", "Pool", "Smoothie Bar", "Recovery"])),
                DetailField("freeTrialOffer", "Free trial / intro offer", .text),
                DetailField("bookingUrl", "Booking / schedule link", .url),
            ]
        case .other:
            return [
                DetailField("hours", "Hours", .hours),
                DetailField("phone", "Phone", .text),
                DetailField("website", "Website", .url),
            ]
        }
    }

    /// Quick area tags offered while tagging the walkthrough.
    var quickTags: [String] {
        switch self {
        case .realEstate:
            return ["Exterior", "Entry", "Living Room", "Kitchen", "Dining",
                    "Primary", "Bedroom", "Bath", "Office", "Garage", "Backyard"]
        case .venue:
            return ["Entrance", "Main Hall", "Stage", "Bar", "Lounge",
                    "Patio", "Garden", "Kitchen", "Restrooms", "Green Room"]
        case .restaurant:
            return ["Entrance", "Dining", "Bar", "Patio", "Private Room",
                    "Kitchen", "Restrooms"]
        case .retail:
            return ["Entrance", "Front", "Aisles", "Produce", "Deli",
                    "Checkout", "Backroom"]
        case .fitness:
            return ["Entrance", "Reception", "Main Floor", "Weights", "Studio",
                    "Cardio", "Locker Room", "Showers"]
        case .other:
            return ["Entrance", "Main Area", "Front", "Back", "Outside", "Restrooms"]
        }
    }
}

// MARK: - Dynamic detail fields
// A typed input schema so each business type collects and displays the right
// data without hardcoding a screen per industry.
enum FieldInputType: Equatable {
    case text
    case number
    case price
    case priceRange
    case hours
    case multilineText
    case toggle
    case url
    case singleSelect([String])
    case multiSelect([String])
}

struct DetailField: Identifiable {
    let key: String
    let label: String
    let type: FieldInputType
    var id: String { key }

    init(_ key: String, _ label: String, _ type: FieldInputType) {
        self.key = key
        self.label = label
        self.type = type
    }

    var isURL: Bool { if case .url = type { return true }; return false }

    /// Human-readable rendering of a stored value for the customer-facing detail.
    func display(_ raw: String) -> String {
        switch type {
        case .toggle:
            return raw == "true" ? "Yes" : "No"
        case .multiSelect:
            return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " · ")
        default:
            return raw
        }
    }
}
