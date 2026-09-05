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
    /// The full public share URL returned by the server (e.g. rendprop.com/f/<slug>).
    var shareURL: String? = nil

    // MARK: - Added 2026-09-03 (audit). ALL optional → snapshots from older builds decode.
    /// Exterior photo (Documents-relative) used to ground the AI aerial intro so
    /// the model sees THIS property. Defaults to the main photo when unset.
    var exteriorPhotoRelPath: String? = nil
    /// City/State (never the street) from the geocode placemark — sent to the
    /// aerial generator as scenery context. Street address never leaves the phone.
    var regionLabel: String? = nil
    /// The latest generated aerial clip (Documents-relative) + when it was made.
    var aerialRelPath: String? = nil
    var aerialGeneratedAt: Date? = nil
    /// Human-readable reason the last render/publish failed (shown on the card /
    /// detail so the user can retry instead of a listing stuck "Working on it").
    var lastError: String? = nil
    /// True when a local edit (sold, Zillow, details, photo) hasn't been PATCHed to
    /// the server yet. Only meaningful once `serverID` is set.
    var needsServerSync: Bool? = nil
    /// Server `renders.id` of the published tour (from /renders/publish-app).
    var publishedRenderID: UUID? = nil

    // MARK: - Added 2026-09-04 (compliance wave W2-C). ALL optional → older snapshots decode.
    /// The MLS-safe UNBRANDED link (`/u/<slug>`) the server returns as
    /// `unbranded_url` on publish. The branded `/f/` link carries the agent card,
    /// the CTA and the lead form; unbranded virtual-tour rules ban all three, and
    /// the unbranded field is the one that syndicates to Zillow/Realtor.com.
    /// Optional: tours published by an earlier build have none, so
    /// `serverUnbrandedURL` derives it instead.
    var unbrandedShareURL: String? = nil
    /// The geocode's administrative area ("CA", "NC") — city/state only, never
    /// the street. Drives the California AB 723 compliance banner without
    /// re-geocoding on every open.
    var stateCode: String? = nil

    func detail(_ key: String) -> String { details?[key] ?? "" }

    /// The last render/publish attempt failed (or was interrupted). Cards show a
    /// "Needs attention" chip and the detail screen offers the next action.
    var needsAttention: Bool {
        guard let e = lastError?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return !e.isEmpty
    }

    /// The public server share link for this listing's published tour, if any.
    /// Prefer the full `shareURL`; else rebuild the canonical link from the slug.
    /// Nil when the tour hasn't been published to the cloud yet — callers then
    /// fall back to the local-only preview link.
    var serverShareURL: URL? {
        if let s = shareURL?.trimmingCharacters(in: .whitespaces), !s.isEmpty,
           let u = URL(string: s) { return u }
        if let slug = shareSlug?.trimmingCharacters(in: .whitespaces), !slug.isEmpty {
            return URL(string: "https://rendprop.com/f/\(slug)")
        }
        return nil
    }

    /// The MLS-SAFE unbranded link (`/u/<slug>`) for this listing's published
    /// tour — the property and nothing else. Prefer the server's own
    /// `unbranded_url`; otherwise derive it from the branded link (same host,
    /// `/f/` → `/u/`) so tours published before this field existed still get
    /// one; otherwise rebuild it from the slug. Nil until the tour is published
    /// — never fabricated (a `/u/<uuid>` link 404s for the MLS just as a
    /// fabricated `/f/` one does).
    var serverUnbrandedURL: URL? {
        if let s = unbrandedShareURL?.trimmingCharacters(in: .whitespaces), !s.isEmpty,
           let u = URL(string: s) { return u }
        if let branded = shareURL?.trimmingCharacters(in: .whitespaces), !branded.isEmpty,
           branded.contains("/f/") {
            let swapped = branded.replacingOccurrences(of: "/f/", with: "/u/")
            if let u = URL(string: swapped) { return u }
        }
        if let slug = shareSlug?.trimmingCharacters(in: .whitespaces), !slug.isEmpty {
            return URL(string: "https://rendprop.com/u/\(slug)")
        }
        return nil
    }

    /// True when this listing geocoded to California. California AB 723 (in
    /// force 1 Jan 2026) requires BOTH the disclosure of digitally altered
    /// listing imagery AND access to the unaltered originals, at up to $2,500
    /// per violation — the compliance card says so out loud. Falls back to the
    /// trailing token of `regionLabel` ("Sausalito, CA") for listings geocoded
    /// before `stateCode` existed.
    var isCalifornia: Bool {
        func isCA(_ raw: String) -> Bool {
            let t = raw.trimmingCharacters(in: .whitespaces)
            return t.caseInsensitiveCompare("CA") == .orderedSame
                || t.caseInsensitiveCompare("California") == .orderedSame
        }
        if let code = stateCode, !code.trimmingCharacters(in: .whitespaces).isEmpty {
            return isCA(code)
        }
        guard let region = regionLabel, !region.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard let tail = region.split(separator: ",").last else { return false }
        return isCA(String(tail))
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
        guard let key = spaceType.actionURLKey else { return nil }
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

    /// Absolute URL of the exterior photo used for the aerial intro (falls back to
    /// the main photo), if the file still exists.
    var exteriorPhotoURL: URL? {
        if let p = exteriorPhotoRelPath {
            let url = FileStore.url(fromRelativePath: p)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return mainPhotoURL
    }

    /// Absolute URL of the generated aerial clip, if the file still exists.
    var aerialURL: URL? {
        guard let p = aerialRelPath else { return nil }
        let url = FileStore.url(fromRelativePath: p)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Property facts line. Zero/unknown values are hidden (never "0 bd · 0 ba").
    var metaLine: String {
        var parts: [String] = []
        if beds > 0 { parts.append("\(beds) bd") }
        if baths > 0 {
            let bathsText = baths.truncatingRemainder(dividingBy: 1) == 0
                ? String(Int(baths)) : String(baths)
            parts.append("\(bathsText) ba")
        }
        if sqft > 0 { parts.append("\(sqft.formatted()) sqft") }
        return parts.joined(separator: " · ")
    }

    /// The card/detail subtitle, adapted to THIS listing's business type:
    /// property details for real estate, the free-text tagline for everyone else.
    var subtitleLine: String {
        spaceType.showsPropertyDetails ? metaLine : (tagline ?? "")
    }

    /// Per-industry info chips for the listing card — a venue shows capacity
    /// and starting price, a restaurant its cuisine/$$$/hours, a gym its
    /// membership. Real estate keeps beds/baths/price in the classic layout.
    /// Prices typed with separators ("3,500", "$49") still parse.
    var cardChips: [String] {
        var chips: [String] = []
        func add(_ s: String) {
            let t = s.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { chips.append(t) }
        }
        switch spaceType {
        case .realEstate:
            break
        case .venue:
            if !detail("capacitySeated").isEmpty { add("Seats \(detail("capacitySeated"))") }
            if let v = Money.parseDollars(detail("startingPrice")), v > 0 { add("From \(Money.dollars(v).formatted)") }
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
            if let m = Money.parseDollars(detail("membershipPrice")), m > 0 { add("\(Money.dollars(m).formatted)/mo") }
            if detail("is247") == "true" { add("Open 24/7") }
            if !detail("freeTrialOffer").isEmpty { add("Free trial") }
        case .other:
            add(detail("hours"))
        }
        return Array(chips.prefix(3))
    }
}

// MARK: - Tolerant decoding (persistence forward/backward compatibility)
// PersistentStore decodes snapshots written by OLDER and NEWER app builds.
// Synthesized Codable requires every non-optional key (even ones with default
// values) and throws on unknown enum raw values — a single miss would discard
// the user's entire saved state on update. This init decodes each field with
// decodeIfPresent + a safe default so any snapshot vintage loads. It lives in
// an extension so the memberwise initializer stays synthesized (the app builds
// Listings memberwise everywhere). Encoding stays synthesized → identical JSON.
extension Listing {
    enum CodingKeys: String, CodingKey {
        case id, address, beds, baths, sqft, price, status, isSample, spaceTypeRaw,
             createdAt, soldAt, zillowURL, mainPhotoRelPath, latitude, longitude,
             tagline, details, serverID, shareSlug, shareURL,
             exteriorPhotoRelPath, regionLabel, aerialRelPath, aerialGeneratedAt,
             lastError, needsServerSync, publishedRenderID,
             unbrandedShareURL, stateCode
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id               = try c.decodeIfPresent(UUID.self,   forKey: .id) ?? UUID()
        address          = try c.decodeIfPresent(String.self, forKey: .address) ?? ""
        beds             = try c.decodeIfPresent(Int.self,    forKey: .beds) ?? 0
        baths            = try c.decodeIfPresent(Double.self, forKey: .baths) ?? 0
        sqft             = try c.decodeIfPresent(Int.self,    forKey: .sqft) ?? 0
        price            = try c.decodeIfPresent(Money.self,  forKey: .price) ?? Money(cents: 0)
        // Unknown status raw values (from a newer build) degrade to .draft
        // instead of throwing the whole snapshot away.
        let statusRaw    = try c.decodeIfPresent(String.self, forKey: .status)
        status           = statusRaw.flatMap(Status.init(rawValue:)) ?? .draft
        isSample         = try c.decodeIfPresent(Bool.self,   forKey: .isSample) ?? false
        spaceTypeRaw     = try c.decodeIfPresent(String.self, forKey: .spaceTypeRaw)
        createdAt        = try c.decodeIfPresent(Date.self,   forKey: .createdAt) ?? Date()
        soldAt           = try c.decodeIfPresent(Date.self,   forKey: .soldAt)
        zillowURL        = try c.decodeIfPresent(String.self, forKey: .zillowURL)
        mainPhotoRelPath = try c.decodeIfPresent(String.self, forKey: .mainPhotoRelPath)
        latitude         = try c.decodeIfPresent(Double.self, forKey: .latitude)
        longitude        = try c.decodeIfPresent(Double.self, forKey: .longitude)
        tagline          = try c.decodeIfPresent(String.self, forKey: .tagline)
        details          = try c.decodeIfPresent([String: String].self, forKey: .details)
        serverID         = try c.decodeIfPresent(UUID.self,   forKey: .serverID)
        shareSlug        = try c.decodeIfPresent(String.self, forKey: .shareSlug)
        shareURL         = try c.decodeIfPresent(String.self, forKey: .shareURL)
        exteriorPhotoRelPath = try c.decodeIfPresent(String.self, forKey: .exteriorPhotoRelPath)
        regionLabel      = try c.decodeIfPresent(String.self, forKey: .regionLabel)
        aerialRelPath    = try c.decodeIfPresent(String.self, forKey: .aerialRelPath)
        aerialGeneratedAt = try c.decodeIfPresent(Date.self,  forKey: .aerialGeneratedAt)
        lastError        = try c.decodeIfPresent(String.self, forKey: .lastError)
        needsServerSync  = try c.decodeIfPresent(Bool.self,   forKey: .needsServerSync)
        publishedRenderID = try c.decodeIfPresent(UUID.self,  forKey: .publishedRenderID)
        unbrandedShareURL = try c.decodeIfPresent(String.self, forKey: .unbrandedShareURL)
        stateCode        = try c.decodeIfPresent(String.self, forKey: .stateCode)
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

    /// Home hero headline — the emotional promise, two short lines, in the
    /// owner's words: it should hit what the app DOES for them (win the
    /// listing, book the date, fill the room), not describe the mechanics.
    /// Fair-housing safe: never people, neighborhoods or demographics.
    var heroHeadline: String {
        switch self {
        case .realEstate: return "Win the listing.\nSkip the film crew."
        case .venue:      return "Book the date before\nthey ever visit."
        case .restaurant: return "Fill the room before\nthey see the menu."
        case .retail:     return "Get them in the door\nfrom their couch."
        case .fitness:    return "Sell the feeling\nbefore the first class."
        case .other:      return "Show your space\nlike a film."
        }
    }

    /// Home hero subline — what one walkthrough turns into, for this audience.
    var heroSubline: String {
        switch self {
        case .realEstate:
            return "One walkthrough becomes a cinematic tour, polished photos and a link buyers can't stop scrolling — in minutes, from your phone."
        case .venue:
            return "Walk the room once. Get a cinematic tour, polished photos and a link planners share before they've booked a visit."
        case .restaurant:
            return "Walk it once. Get a cinematic tour, mouth-watering photos and a link guests share — in minutes, from your phone."
        case .retail:
            return "One walkthrough becomes a cinematic tour, polished photos and a link shoppers can scroll before they visit."
        case .fitness:
            return "Walk the floor once. Get a cinematic tour, polished photos and a link that sells the space before the first class."
        case .other:
            return "One walkthrough becomes a cinematic tour, polished photos and a link customers can scroll — in minutes, from your phone."
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

    /// Stable per-type index (1-based) — part of every sample's deterministic id.
    private var sampleTypeIndex: UInt8 {
        switch self {
        case .realEstate: return 1
        case .venue:      return 2
        case .restaurant: return 3
        case .retail:     return 4
        case .fitness:    return 5
        case .other:      return 6
        }
    }

    /// Deterministic sample id: the same sample has the SAME id on every launch
    /// and type switch, so anything keyed by listing id can't be orphaned by a
    /// relaunch (decision A7). Built from raw bytes — non-failable, no `!`.
    /// Layout: 0000000n-0000-4000-8000-00000000000t (n = sample #, t = type).
    func sampleID(_ n: UInt8) -> UUID {
        UUID(uuid: (0, 0, 0, n,
                    0, 0,
                    0x40, 0,
                    0x80, 0,
                    0, 0, 0, 0, 0, sampleTypeIndex))
    }

    /// True for ids minted by `sampleID` (any type / index).
    static func isSampleID(_ id: UUID) -> Bool {
        let u = id.uuid
        return u.0 == 0 && u.1 == 0 && u.2 == 0 && u.4 == 0 && u.5 == 0
            && u.6 == 0x40 && u.7 == 0 && u.8 == 0x80 && u.9 == 0
            && u.10 == 0 && u.11 == 0 && u.12 == 0 && u.13 == 0 && u.14 == 0
    }

    /// Believable seeded sample(s) for this business type — so the first screen
    /// a venue owner sees is a venue, not a house. Never persisted (isSample).
    /// Every sample is stamped with its type so per-listing copy/chips resolve
    /// from the listing itself, and carries a stable id (see `sampleID`).
    var sampleListings: [Listing] {
        switch self {
        case .realEstate:
            return [
                Listing(id: sampleID(1), address: "1247 Hillcrest Drive (Sample)", beds: 4, baths: 3, sqft: 2850,
                        price: .dollars(1_175_000), status: .ready, isSample: true, spaceTypeRaw: rawValue),
                // Both samples are finished demos — a permanently "Working on it"
                // sample looked like a stuck render.
                Listing(id: sampleID(2), address: "88 Marina Vista #501 (Sample)", beds: 2, baths: 2, sqft: 1240,
                        price: .dollars(689_000), status: .ready, isSample: true, spaceTypeRaw: rawValue),
            ]
        case .venue:
            var l = Listing(id: sampleID(1), address: "The Grand Atrium (Sample)", beds: 0, baths: 0, sqft: 0,
                            price: Money(cents: 0), status: .ready, isSample: true, spaceTypeRaw: rawValue)
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
            var l = Listing(id: sampleID(1), address: "Bella Notte (Sample)", beds: 0, baths: 0, sqft: 0,
                            price: Money(cents: 0), status: .ready, isSample: true, spaceTypeRaw: rawValue)
            l.tagline = "Italian · Wine Bar · $$$"
            l.details = [
                "cuisineType": "Italian, Wine Bar", "priceRange": "$$$",
                "hours": "Tue–Sun 5–11pm",
                "amenities": "Outdoor Seating, Full Bar, Private Dining, Happy Hour",
                "phone": "(555) 014-2200",
            ]
            return [l]
        case .retail:
            var l = Listing(id: sampleID(1), address: "Fresh Market (Sample)", beds: 0, baths: 0, sqft: 0,
                            price: Money(cents: 0), status: .ready, isSample: true, spaceTypeRaw: rawValue)
            l.tagline = "Neighborhood grocery · Open daily 7am–9pm"
            l.details = [
                "storeCategory": "Grocery", "hours": "Daily 7am–9pm",
                "weeklySpecial": "Local strawberries — 2 for 1 this week",
                "shoppingOptions": "In-store, Curbside Pickup, Local Delivery",
                "departments": "Produce, Deli, Bakery, Dairy, Frozen",
            ]
            return [l]
        case .fitness:
            var l = Listing(id: sampleID(1), address: "Iron & Oak Strength Co. (Sample)", beds: 0, baths: 0, sqft: 0,
                            price: Money(cents: 0), status: .ready, isSample: true, spaceTypeRaw: rawValue)
            l.tagline = "Strength gym · Open 24/7 · Classes daily"
            l.details = [
                "facilityType": "Gym", "membershipPrice": "49", "dayPassPrice": "15",
                "is247": "true",
                "amenities": "Showers, Sauna, Lockers, Parking, Smoothie Bar",
                "freeTrialOffer": "7-day free trial",
            ]
            return [l]
        case .other:
            var l = Listing(id: sampleID(1), address: "The Workshop (Sample)", beds: 0, baths: 0, sqft: 0,
                            price: Money(cents: 0), status: .ready, isSample: true, spaceTypeRaw: rawValue)
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
        case .price:
            // "49" / "$3,500" → "$49" / "$3,500"; anything non-numeric shows as typed.
            if let d = Money.parseDollars(raw), d > 0 { return Money.dollars(d).formatted }
            return raw
        default:
            return raw
        }
    }
}
