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
