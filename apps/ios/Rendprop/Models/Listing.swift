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
    /// Which business type created this listing. Optional so listings saved
    /// before this field existed still decode — those legacy listings are
    /// treated as real estate (the original default). A gym only ever sees gym
    /// listings; real-estate sold houses never leak into Food mode.
    var spaceTypeRaw: String? = nil
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

    // MARK: - Cloud sync (local-first + cloud-publish, contract §4)
    // All optional so listings saved before these fields existed still decode.
    /// The server `listings.id` adopted on first publish. Once set, every server
    /// call for this listing (uploads, publish) uses this id, not the local `id`.
    var serverID: UUID? = nil
    /// The published tour's server slug (never fabricated from the local UUID).
    var shareSlug: String? = nil
    /// The full public share URL returned by the server (e.g. rendprop.app/f/<slug>).
    var shareURL: String? = nil

    func detail(_ key: String) -> String { details?[key] ?? "" }

    /// The public server share link for this listing's published tour, if any.
    /// Prefer the full `shareURL`; else rebuild the canonical link from the slug.
    /// Nil when the tour hasn't been published to the cloud yet — callers then
    /// fall back to the local-only preview link.
    var serverShareURL: URL? {
        if let s = shareURL?.trimmingCharacters(in: .whitespaces), !s.isEmpty,
           let u = URL(string: s) { return u }
        if let slug = shareSlug?.trimmingCharacters(in: .whitespaces), !slug.isEmpty {
            return URL(string: "https://rendprop.app/f/\(slug)")
        }
        return nil
    }

    /// The business type this listing belongs to. Legacy listings (nil) and
    /// samples default to real estate.
    var spaceType: SpaceType {
        SpaceType(rawValue: spaceTypeRaw ?? "") ?? .realEstate
    }

    /// True when this listing belongs to the currently-selected business type.
    /// Samples are always shown (they're reseeded per type already).
    var belongsToCurrentType: Bool {
        isSample || spaceType == SpaceType.current
    }

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

    /// Per-industry info chips for the listing card — a venue shows capacity
    /// and starting price, a restaurant its cuisine/$$$/hours, a gym its
    /// membership. Real estate keeps beds/baths/price in the classic layout.
    var cardChips: [String] {
        var chips: [String] = []
        func add(_ s: String) {
            let t = s.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { chips.append(t) }
        }
        switch SpaceType.current {
        case .realEstate:
            break
        case .venue:
            if !detail("capacitySeated").isEmpty { add("Seats \(detail("capacitySeated"))") }
            if let v = Int(detail("startingPrice")) { add("From \(Money.dollars(v).formatted)") }
            add(detail("eventTypes").components(separatedBy: ",").first ?? "")
        case .restaurant:
            add(detail("cuisineType").components(separatedBy: ",").first ?? "")
            add(detail("priceRange"))
            add(detail("hours"))
        case .retail:
            add(detail("storeCategory"))
            add(detail("hours"))
            if !detail("weeklySpecial").isEmpty { add("★ \(detail("weeklySpecial"))") }
        case .fitness:
            if let m = Int(detail("membershipPrice")) { add("\(Money.dollars(m).formatted)/mo") }
            if detail("is247") == "true" { add("Open 24/7") }
            if !detail("freeTrialOffer").isEmpty { add("Free trial") }
        case .other:
            add(detail("hours"))
        }
        return Array(chips.prefix(3))
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

    /// Profile identity flips per type: real estate profiles the AGENT
    /// (person + brokerage); every other type profiles the BUSINESS
    /// (business name + owner). Same storage, different meaning.
    var profileCardName: String { self == .realEstate ? "Agent card" : "Business card" }
    var profileNameLabel: String { self == .realEstate ? "Full name" : "Business name" }
    var profileOrgLabel: String { self == .realEstate ? "Brokerage" : "Owner or manager (optional)" }
    var profilePhotoLabel: String { self == .realEstate ? "Headshot" : "Logo or photo" }

    /// Who watches this type's tours — used everywhere the copy says "buyers".
    var customerNoun: String {
        switch self {
        case .realEstate: return "buyers"
        case .venue:      return "planners"
        case .restaurant: return "guests"
        case .retail:     return "shoppers"
        case .fitness:    return "members"
        case .other:      return "customers"
        }
    }

    /// One-line pitch for the Business tab type cards.
    var pitch: String {
        switch self {
        case .realEstate: return "Sell homes with cinematic tours"
        case .venue:      return "Book more events"
        case .restaurant: return "Fill more tables"
        case .retail:     return "Bring shoppers through the door"
        case .fitness:    return "Sign up more members"
        case .other:      return "Show off any space"
        }
    }

    /// One line of flavor under the empty-state headline, per industry.
    var emptyStateLine: String {
        switch self {
        case .realEstate: return "Walk through with your phone.\nWe turn it into a stunning video tour."
        case .venue:      return "Walk the space with your phone.\nCouples and planners tour it before they ever call."
        case .restaurant: return "Walk the room with your phone.\nGuests feel the vibe before they book a table."
        case .retail:     return "Walk the aisles with your phone.\nShoppers see the store before they visit."
        case .fitness:    return "Walk the floor with your phone.\nMembers tour the gym before their first visit."
        case .other:      return "Walk through with your phone.\nCustomers tour your space before they arrive."
        }
    }

    /// Believable seeded sample(s) for this business type — so the first screen
    /// a venue owner sees is a venue, not a house. Never persisted (isSample).
    var sampleListings: [Listing] {
        switch self {
        case .realEstate:
            return [
                Listing(address: "1247 Hillcrest Drive (Sample)", beds: 4, baths: 3, sqft: 2850,
                        price: .dollars(1_175_000), status: .ready, isSample: true),
                Listing(address: "88 Marina Vista #501 (Sample)", beds: 2, baths: 2, sqft: 1240,
                        price: .dollars(689_000), status: .processing, isSample: true),
            ]
        case .venue:
            var l = Listing(address: "The Grand Atrium (Sample)", beds: 0, baths: 0, sqft: 0,
                            price: Money(cents: 0), status: .ready, isSample: true)
            l.tagline = "Historic ballroom · Seats 220"
            l.details = [
                "capacitySeated": "220", "capacityStanding": "350",
                "startingPrice": "3500",
                "eventTypes": "Wedding, Corporate, Gala",
                "catering": "In-house or outside", "spaceSetting": "Both",
                "amenities": "Tables & Chairs, AV / Sound, Stage, Dance Floor, Parking, Bar",
            ]
            return [l]
        case .restaurant:
            var l = Listing(address: "Bella Notte (Sample)", beds: 0, baths: 0, sqft: 0,
                            price: Money(cents: 0), status: .ready, isSample: true)
            l.tagline = "Italian · Wine Bar · $$$"
            l.details = [
                "cuisineType": "Italian, Wine Bar", "priceRange": "$$$",
                "hours": "Tue–Sun 5–11pm",
                "amenities": "Outdoor Seating, Full Bar, Private Dining, Happy Hour",
                "phone": "(555) 014-2200",
            ]
            return [l]
        case .retail:
            var l = Listing(address: "Fresh Market (Sample)", beds: 0, baths: 0, sqft: 0,
                            price: Money(cents: 0), status: .ready, isSample: true)
            l.tagline = "Neighborhood grocery · Open daily 7am–9pm"
            l.details = [
                "storeCategory": "Grocery", "hours": "Daily 7am–9pm",
                "weeklySpecial": "Local strawberries — 2 for 1 this week",
                "shoppingOptions": "In-store, Curbside Pickup, Local Delivery",
                "departments": "Produce, Deli, Bakery, Dairy, Frozen",
            ]
            return [l]
        case .fitness:
            var l = Listing(address: "Iron & Oak Strength Co. (Sample)", beds: 0, baths: 0, sqft: 0,
                            price: Money(cents: 0), status: .ready, isSample: true)
            l.tagline = "Strength gym · Open 24/7 · Classes daily"
            l.details = [
                "facilityType": "Gym", "membershipPrice": "49", "dayPassPrice": "15",
                "is247": "true",
                "amenities": "Showers, Sauna, Lockers, Parking, Smoothie Bar",
                "freeTrialOffer": "7-day free trial",
            ]
            return [l]
        case .other:
            var l = Listing(address: "The Workshop (Sample)", beds: 0, baths: 0, sqft: 0,
                            price: Money(cents: 0), status: .ready, isSample: true)
            l.tagline = "Creative studio & community space"
            l.details = ["hours": "Mon–Sat 9am–6pm"]
            return [l]
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
