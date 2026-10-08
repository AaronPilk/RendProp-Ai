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
    /// Studio can archive a listing without marking it sold. Preserve both states.
    var cloudArchived: Bool? = nil
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
    /// Editable room measurements, separate from a RoomPlan scan. The raw
    /// details value stays available when a newer wire version cannot decode.
    var floorMeasurements: FloorMeasurementPlan? = nil
    /// Per-listing client identity. Never changes the account owner's brand kit.
    var clientContact: ListingClientContact? = nil
    var clientContactDirty: Bool? = nil
    var clientContactLoaded: Bool? = nil
    var clientPhotoRelPath: String? = nil
    var clientPhotoDirty: Bool? = nil

    // MARK: - Cloud sync (local-first + cloud-publish, contract §4)
    // All optional so listings saved before these fields existed still decode.
    /// The server `listings.id` adopted on first publish. Once set, every server
    /// call for this listing (uploads, publish) uses this id, not the local `id`.
    var serverID: UUID? = nil
    /// The shared workspace that owns this server row (including team listings).
    var serverOrgID: UUID? = nil
    /// The selected workspace when this local draft was created; retries never retarget it.
    var cloudDraftOrgID: UUID? = nil
    /// True for a row first discovered on another device. Optional for old snapshots.
    var cloudImported: Bool? = nil
    /// A complete cloud read no longer returned this listing. Keep local files,
    /// but do not recreate or publish into a workspace whose access has changed.
    var cloudUnavailable: Bool? = nil
    /// Keeps automatic draft sync within the account that created this draft.
    var cloudSyncOwnerID: UUID? = nil
    /// Retained across account changes so returning to the same account can
    /// reattach an authorized row without creating another listing.
    var cloudDetachedServerID: UUID? = nil
    /// Initial facts fingerprint survives an interrupted first create.
    var cloudCreateFingerprint: String? = nil
    /// Separates ordinary listing edits from measurement-only create retries.
    var cloudCreateFactsFingerprint: String? = nil
    /// Response metadata used only while adopting a create receipt.
    var cloudCreateReplayed: Bool? = nil
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
    /// Only explicitly edited facts may leave this phone; old ambiguous dirty
    /// snapshots remain local until their shared details are reviewed.
    var factsSync: ListingFactsSyncState? = nil
    /// Measurement-only CAS state persists across offline edits and relaunches.
    var measurementSync: FloorMeasurementSyncState? = nil
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

    // MARK: - Added 2026-09-12 (1.0.2). Optional → older snapshots decode.
    /// SEARCH-ENGINE OPT-IN for this listing's hosted tour page, answered by the
    /// owner on the publish screen. nil = never asked (the server's own default
    /// applies, which is `noindex`); false = they said no; true = they said yes.
    ///
    /// WHY IT IS A FIELD AND NOT A `details` KEY, which is where the server
    /// reads it from: `ListingFormData.apply(to:)` sets `details = nil` for
    /// every real-estate listing, so a flag parked in that bag would be wiped
    /// the first time an agent tapped "Edit details" — silently un-listing a
    /// page they had asked to be listed. `LiveAPIClient.listingBody` merges this
    /// into the wire `details` under the key the tour host actually reads
    /// (`allow_indexing` — services/edge/tour-host/src/player.ts,
    /// `allowsIndexing`), so the transport is unchanged and the local truth
    /// survives every edit path.
    var allowSearchIndexing: Bool? = nil

    /// The wire key for `allowSearchIndexing`, inside the listing's `details`
    /// bag. `allowsIndexing()` accepts three spellings and checks them in the
    /// order `allow_indexing`, `allowIndexing`, `search_indexing`, stopping at
    /// the first one present — so this one wins, and it is the spelling the
    /// Worker's own tests, its README and the sitemap all use.
    static let searchIndexingKey = "allow_indexing"

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
    ///
    /// REAL ESTATE ONLY. The MLS is a real-estate institution; a bar, venue,
    /// store or gym has no unbranded-field rule to follow and must never be
    /// shown an "MLS link" (industry review P1-2). The server still publishes
    /// the `/u/` twin for every type — this only decides what the app surfaces.
    var serverUnbrandedURL: URL? {
        guard spaceType == .realEstate else { return nil }
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
    var isArchived: Bool {
        cloudArchived ?? (factsSync?.baseline["status"] == .text("archived") && factsSync?.fields["status"]?.value != .text("ready"))
    }
    var isInactive: Bool { isSold || isArchived }
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
             createdAt, soldAt, cloudArchived, zillowURL, mainPhotoRelPath, latitude, longitude,
             tagline, details, floorMeasurements, serverID, serverOrgID, cloudDraftOrgID, cloudImported, cloudUnavailable, cloudSyncOwnerID, cloudDetachedServerID, cloudCreateFingerprint, cloudCreateFactsFingerprint, cloudCreateReplayed, shareSlug, shareURL,
             exteriorPhotoRelPath, regionLabel, aerialRelPath, aerialGeneratedAt,
             lastError, needsServerSync, factsSync, measurementSync, publishedRenderID,
             unbrandedShareURL, stateCode, allowSearchIndexing,
             clientContact, clientContactDirty, clientContactLoaded, clientPhotoRelPath, clientPhotoDirty
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
        cloudArchived    = try c.decodeIfPresent(Bool.self, forKey: .cloudArchived)
        zillowURL        = try c.decodeIfPresent(String.self, forKey: .zillowURL)
        mainPhotoRelPath = try c.decodeIfPresent(String.self, forKey: .mainPhotoRelPath)
        latitude         = try c.decodeIfPresent(Double.self, forKey: .latitude)
        longitude        = try c.decodeIfPresent(Double.self, forKey: .longitude)
        tagline          = try c.decodeIfPresent(String.self, forKey: .tagline)
        details          = try c.decodeIfPresent([String: String].self, forKey: .details)
        // Unsupported or damaged measurement data must not discard the rest
        // of a saved listing. Only an absent local field recovers raw wire data;
        // an explicit null remains cleared, and a future typed value stays nil.
        if c.contains(.floorMeasurements) {
            if let candidate = try? c.decodeIfPresent(FloorMeasurementPlan.self, forKey: .floorMeasurements),
               (try? candidate.validate()) != nil {
                floorMeasurements = candidate
            } else {
                floorMeasurements = nil
            }
        } else {
            floorMeasurements = FloorMeasurementPlan.decodeWireValue(FloorMeasurementPlan.wireValue(in: details))
        }
        clientContact = try c.decodeIfPresent(ListingClientContact.self, forKey: .clientContact)
        clientContactDirty = try c.decodeIfPresent(Bool.self, forKey: .clientContactDirty)
        clientContactLoaded = try c.decodeIfPresent(Bool.self, forKey: .clientContactLoaded)
        clientPhotoRelPath = try c.decodeIfPresent(String.self, forKey: .clientPhotoRelPath)
        clientPhotoDirty = try c.decodeIfPresent(Bool.self, forKey: .clientPhotoDirty)
        serverID         = try c.decodeIfPresent(UUID.self,   forKey: .serverID)
        serverOrgID      = try c.decodeIfPresent(UUID.self,   forKey: .serverOrgID)
        cloudDraftOrgID  = try c.decodeIfPresent(UUID.self, forKey: .cloudDraftOrgID)
        cloudImported    = try c.decodeIfPresent(Bool.self,   forKey: .cloudImported)
        cloudUnavailable = try c.decodeIfPresent(Bool.self,   forKey: .cloudUnavailable)
        cloudSyncOwnerID = try c.decodeIfPresent(UUID.self, forKey: .cloudSyncOwnerID)
        cloudDetachedServerID = try c.decodeIfPresent(UUID.self, forKey: .cloudDetachedServerID)
        cloudCreateFingerprint = try c.decodeIfPresent(String.self, forKey: .cloudCreateFingerprint)
        cloudCreateFactsFingerprint = try c.decodeIfPresent(String.self, forKey: .cloudCreateFactsFingerprint)
        cloudCreateReplayed = try c.decodeIfPresent(Bool.self, forKey: .cloudCreateReplayed)
        shareSlug        = try c.decodeIfPresent(String.self, forKey: .shareSlug)
        shareURL         = try c.decodeIfPresent(String.self, forKey: .shareURL)
        exteriorPhotoRelPath = try c.decodeIfPresent(String.self, forKey: .exteriorPhotoRelPath)
        regionLabel      = try c.decodeIfPresent(String.self, forKey: .regionLabel)
        aerialRelPath    = try c.decodeIfPresent(String.self, forKey: .aerialRelPath)
        aerialGeneratedAt = try c.decodeIfPresent(Date.self,  forKey: .aerialGeneratedAt)
        lastError        = try c.decodeIfPresent(String.self, forKey: .lastError)
        needsServerSync  = try c.decodeIfPresent(Bool.self,   forKey: .needsServerSync)
        factsSync = try c.decodeIfPresent(ListingFactsSyncState.self, forKey: .factsSync)
        measurementSync = try c.decodeIfPresent(FloorMeasurementSyncState.self, forKey: .measurementSync)
        publishedRenderID = try c.decodeIfPresent(UUID.self,  forKey: .publishedRenderID)
        unbrandedShareURL = try c.decodeIfPresent(String.self, forKey: .unbrandedShareURL)
        stateCode        = try c.decodeIfPresent(String.self, forKey: .stateCode)
        allowSearchIndexing = try c.decodeIfPresent(Bool.self, forKey: .allowSearchIndexing)
        FloorMeasurementSync.recoverLegacyPending(in: &self)
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
    /// "homes" / "venues" / "places" / "stores" / "studios" / "spaces".
    var spaceNounPlural: String { spaceNoun + "s" }

    // MARK: Free week (server plan `trial`, sized per industry)
    //
    // The server enforces the week's allowances from `orgs.space_type`
    // (migration 0044): an agent lists several homes at once and gets 3 tours;
    // a venue, restaurant, store, gym or other business is ONE location and
    // gets 1. Photo edits (60) and reel clips (4) are the same everywhere. The
    // app SENDS its type to the server (`AppModel.syncSpaceTypeIfNeeded`) and
    // READS the live numbers from `GET /me` wherever it can (`PlanBanner`);
    // these are the offline / pre-session fallback and the onboarding copy.

    /// A business with one location to tour, as opposed to an agent with a
    /// changing set of listings.
    var isSingleLocation: Bool { self != .realEstate }

    /// Tour renders in the free week.
    var trialTourCount: Int { isSingleLocation ? 1 : 3 }

    /// Aerial intros in the free week.
    var trialAerialCount: Int { isSingleLocation ? 1 : 2 }

    /// AI photo edits in the free week — the same for every industry.
    static let trialPhotoEditCount = 60

    /// Reel clips in the free week — the same for every industry.
    static let trialReelClipCount = 4

    /// "3 tours, 60 photo edits and 4 reel clips" / "1 tour, 60 photo edits
    /// and 4 reel clips". The free-week sentence, minus its ending, so
    /// onboarding ("…, free. No card, no account.") and the Home banner
    /// ("… — 5 days left.") say the same thing.
    var freeWeekLine: String {
        Self.makeFreeWeekLine(tours: trialTourCount,
                              photoEdits: Self.trialPhotoEditCount,
                              reelClips: Self.trialReelClipCount)
    }

    /// The same sentence from live numbers (`GET /me` → `entitlement`), so a
    /// server-side change to the week shows up without an app release.
    static func makeFreeWeekLine(tours: Int, photoEdits: Int, reelClips: Int) -> String {
        let tourNoun = tours == 1 ? "tour" : "tours"
        let editNoun = photoEdits == 1 ? "edit" : "edits"
        let clipNoun = reelClips == 1 ? "clip" : "clips"
        return "\(tours) \(tourNoun), \(photoEdits) photo \(editNoun) and \(reelClips) reel \(clipNoun)"
    }

    /// The trade, for copy that addresses the business rather than the space
    /// ("For a busy gym or studio…"). Real estate is the agent; callers that
    /// carry reviewed real-estate copy branch on `.realEstate` first.
    var businessNoun: String {
        switch self {
        case .realEstate: return "agent"
        case .venue:      return "venue"
        case .restaurant: return "restaurant or bar"
        case .retail:     return "store"
        case .fitness:    return "gym or studio"
        case .other:      return "business"
        }
    }

    /// What one tagged section of the walkthrough is called: a home has rooms,
    /// everything else has areas (the tagger's title already says "Tag areas").
    var areaNoun: String { self == .realEstate ? "room" : "area" }
    var areaNounPlural: String { areaNoun + "s" }

    var collectionTitle: String {
        switch self {
        case .realEstate: return RealEstateRoleStore.current.isProducer ? "Client listings" : "My Listings"
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
            return [DetailField("nearbyAttractions", "Nearby places (reviewed)", .text)]
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
    var profileCardName: String { self == .realEstate ? (RealEstateRoleStore.current.isProducer ? "Your business card" : "Agent card") : "Business card" }
    var profileNameLabel: String { self == .realEstate && !RealEstateRoleStore.current.isProducer ? "Full name" : "Business name" }
    var profileOrgLabel: String { self == .realEstate ? (RealEstateRoleStore.current.isProducer ? "Your name (optional)" : "Brokerage") : "Owner or manager (optional)" }
    var profilePhotoLabel: String { self == .realEstate && !RealEstateRoleStore.current.isProducer ? "Headshot" : "Logo or photo" }

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

    /// Home hero label identifies the agent audience; other roles retain the brand.
    var heroEyebrow: String {
        self == .realEstate && !RealEstateRoleStore.current.isProducer ? "REAL ESTATE AGENT" : "RENDPROP"
    }

    /// Home hero headline wraps naturally in the owner's chosen words.
    /// Fair-housing safe: never people, neighborhoods or demographics.
    var heroHeadline: String {
        switch self {
        case .realEstate: return RealEstateRoleStore.current.isProducer ? "Create for your clients.\nDeliver more from every shoot." : "List it. Launch it. Sell it."
        case .venue:      return "Book the date before\nthey ever visit."
        case .restaurant: return "Fill the room before\nthey see the menu."
        case .retail:     return "Get them in the door\nfrom their couch."
        case .fitness:    return "Sell the feeling\nbefore the first class."
        case .other:      return "Show your space\nlike a film."
        }
    }

    /// Home hero subline describes the tools available to this audience.
    var heroSubline: String {
        switch self {
        case .realEstate:
            return RealEstateRoleStore.current.isProducer
                ? "Capture, edit and deliver listing media. Each client's page shows their contact details, and their inquiries stay organized in your account."
                : "Be your own crew. Capture and polish photos, create tours, social media content, floor plans, virtual staging, and a shareable property site - all from your phone."
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

// MARK: - Editable floor measurements

enum FloorMeasurementUnit: String, Codable, CaseIterable, Hashable, Identifiable {
    case feet, meters

    var id: String { rawValue }
    var label: String { self == .feet ? "Feet" : "Meters" }
}

enum FloorMeasurementSource: String, Codable, Hashable {
    case manual, phoneEstimate
}

enum FloorMeasurementError: Error, LocalizedError, Equatable {
    case unsupportedVersion, tooManyRooms, invalidName, invalidDimension
    case invalidPosition, invalidFloor, invalidRotation, duplicateRoom
    case overlappingRooms, invalidInput, invalidInches, tooLarge, invalidDate
    case tooManyOutlines, invalidVertices, selfIntersectingOutline, duplicateOutline
    case overlappingOutlines, invalidDeduction, deductionOutsideOutline, overlappingDeductions

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion: return "This measurement plan needs a newer app version."
        case .tooManyRooms: return "A measurement plan can contain up to 24 rooms."
        case .invalidName: return "Give each room a name of 1 to 40 characters."
        case .invalidDimension: return "Room dimensions must be between 0.1 and 100 meters."
        case .invalidPosition: return "Room positions must be within 200 meters of the plan origin."
        case .invalidFloor: return "Choose a floor from the second basement through floor 21."
        case .invalidRotation: return "Rotate rooms in quarter turns."
        case .duplicateRoom: return "Each room must have its own identity."
        case .overlappingRooms: return "Rooms on the same floor cannot overlap. Shared edges are allowed."
        case .invalidInput: return "Enter a number using digits and a decimal point or comma."
        case .invalidInches: return "Enter inches from 0 up to, but not including, 12."
        case .tooLarge: return "This measurement plan is too large to save."
        case .invalidDate: return "This measurement plan has an invalid update date."
        case .tooManyOutlines: return "A measurement plan can contain up to 12 area outlines."
        case .invalidVertices: return "An outline needs 3 to 64 distinct corners and walls from 0.1 to 100 meters."
        case .selfIntersectingOutline: return "The outline crosses or doubles back on itself. Check its wall directions."
        case .duplicateOutline: return "Each outline must have its own identity."
        case .overlappingOutlines: return "Area outlines on the same floor cannot overlap. Shared walls are allowed."
        case .invalidDeduction: return "An open-below area must name a finished area on the same floor to subtract from."
        case .deductionOutsideOutline: return "Keep the open-below outline fully inside its finished area, without touching its walls."
        case .overlappingDeductions: return "Open-below deductions on the same floor cannot overlap."
        }
    }
}

/// Coordinates are meters relative to the plan origin. The last corner joins
/// the first implicitly; repeating it would create a zero-length wall.
struct FloorMeasurementPoint: Codable, Hashable {
    var x: Double
    var y: Double
}

enum FloorMeasurementAreaCategory: String, Codable, CaseIterable, Hashable, Identifiable {
    case finished, unfinished, garage, porch, openBelow

    var id: String { rawValue }
    var label: String {
        switch self {
        case .finished: return "Finished"
        case .unfinished: return "Unfinished"
        case .garage: return "Garage"
        case .porch: return "Porch / deck"
        case .openBelow: return "Open below"
        }
    }
}

struct FloorMeasurementOutline: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var floor: Int = 0
    var vertices: [FloorMeasurementPoint]
    var category: FloorMeasurementAreaCategory = .finished
    var deductionFromID: UUID? = nil
    var heightMeters: Double? = nil
    /// The entered walls remain authoritative. This records that the final
    /// joining edge was calculated rather than independently measured.
    var closingWallCalculated: Bool = false
    var source: FloorMeasurementSource = .manual

    var areaMeters2: Double { abs(FloorMeasurementPolygon.signedArea(vertices)) }
    var edgeLengthsMeters: [Double] {
        guard vertices.count > 1 else { return [] }
        return vertices.indices.map {
            FloorMeasurementPolygon.distance(vertices[$0], vertices[($0 + 1) % vertices.count])
        }
    }
    var perimeterMeters: Double { edgeLengthsMeters.reduce(0, +) }
    var floorName: String { FloorMeasurementPlan.floorName(floor) }

    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.count <= 40,
              name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw FloorMeasurementError.invalidName
        }
        guard (-2...20).contains(floor) else { throw FloorMeasurementError.invalidFloor }
        if let heightMeters { try FloorMeasurementInput.validateDimension(heightMeters) }
        guard (3...64).contains(vertices.count) else { throw FloorMeasurementError.invalidVertices }
        guard vertices.allSatisfy({ $0.x.isFinite && $0.y.isFinite
            && (-200...200).contains($0.x) && (-200...200).contains($0.y) }) else {
            throw FloorMeasurementError.invalidPosition
        }
        let tolerance = FloorMeasurementPolygon.tolerance(vertices)
        for i in vertices.indices {
            for j in vertices.indices where j > i {
                guard FloorMeasurementPolygon.distance(vertices[i], vertices[j]) > tolerance else {
                    throw FloorMeasurementError.invalidVertices
                }
            }
        }
        guard edgeLengthsMeters.allSatisfy({ $0 >= 0.1 - tolerance && $0 <= 100 + tolerance }) else {
            throw FloorMeasurementError.invalidVertices
        }
        for i in vertices.indices {
            let a = vertices[i], b = vertices[(i + 1) % vertices.count]
            let c = vertices[(i + 2) % vertices.count]
            // Collinear forward walls are allowed. A reversed run occupies the
            // same boundary twice and cannot define a simple enclosed area.
            if FloorMeasurementPolygon.orientation(a, b, c, tolerance: tolerance) == 0,
               (b.x - a.x) * (c.x - b.x) + (b.y - a.y) * (c.y - b.y) < 0 {
                throw FloorMeasurementError.selfIntersectingOutline
            }
            for j in vertices.indices where j > i {
                if j == i + 1 || (i == 0 && j == vertices.count - 1) { continue }
                if FloorMeasurementPolygon.intersects(a, b, vertices[j], vertices[(j + 1) % vertices.count],
                                                       tolerance: tolerance) {
                    throw FloorMeasurementError.selfIntersectingOutline
                }
            }
        }
        guard areaMeters2.isFinite, areaMeters2 > tolerance * perimeterMeters else {
            throw FloorMeasurementError.invalidVertices
        }
    }
}

extension FloorMeasurementOutline {
    enum CodingKeys: String, CodingKey {
        case id, name, floor, vertices, category, deductionFromID, heightMeters, closingWallCalculated, source
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        floor = try c.decodeIfPresent(Int.self, forKey: .floor) ?? 0
        vertices = try c.decode([FloorMeasurementPoint].self, forKey: .vertices)
        category = try c.decodeIfPresent(FloorMeasurementAreaCategory.self, forKey: .category) ?? .finished
        deductionFromID = try c.decodeIfPresent(UUID.self, forKey: .deductionFromID)
        heightMeters = try c.decodeIfPresent(Double.self, forKey: .heightMeters)
        closingWallCalculated = try c.decodeIfPresent(Bool.self, forKey: .closingWallCalculated) ?? false
        source = try c.decodeIfPresent(FloorMeasurementSource.self, forKey: .source) ?? .manual
    }
}

struct FloorMeasurementWorksheetRow: Hashable, Identifiable {
    let id: UUID
    let name: String
    let floor: Int
    let category: FloorMeasurementAreaCategory
    let grossAreaMeters2: Double
    let deductionAreaMeters2: Double
    let netAreaMeters2: Double
    let perimeterMeters: Double
    let source: FloorMeasurementSource
}

/// Foundation-only simple-polygon predicates. Tolerance only absorbs floating
/// point roundoff at shared boundaries, not a measurable gap or overlap.
private enum FloorMeasurementPolygon {
    static func distance(_ a: FloorMeasurementPoint, _ b: FloorMeasurementPoint) -> Double {
        hypot(a.x - b.x, a.y - b.y)
    }

    static func tolerance(_ vertices: [FloorMeasurementPoint]) -> Double {
        vertices.reduce(1) { max($0, abs($1.x), abs($1.y)) } * Double.ulpOfOne * 64
    }

    static func signedArea(_ vertices: [FloorMeasurementPoint]) -> Double {
        guard let origin = vertices.first, vertices.count >= 3 else { return 0 }
        // Translating to the first corner avoids cancellation from large plan
        // positions when a small outline is far from the origin.
        return vertices.indices.dropFirst().dropLast().reduce(0) { sum, i in
            sum + cross(origin, vertices[i], vertices[i + 1]) / 2
        }
    }

    static func cross(_ a: FloorMeasurementPoint, _ b: FloorMeasurementPoint, _ c: FloorMeasurementPoint) -> Double {
        (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    }

    static func orientation(_ a: FloorMeasurementPoint, _ b: FloorMeasurementPoint,
                            _ c: FloorMeasurementPoint, tolerance: Double) -> Int {
        let value = cross(a, b, c)
        let bound = tolerance * max(1, distance(a, b))
        return value > bound ? 1 : (value < -bound ? -1 : 0)
    }

    static func onSegment(_ p: FloorMeasurementPoint, _ a: FloorMeasurementPoint,
                          _ b: FloorMeasurementPoint, tolerance: Double) -> Bool {
        orientation(a, b, p, tolerance: tolerance) == 0
            && p.x >= min(a.x, b.x) - tolerance && p.x <= max(a.x, b.x) + tolerance
            && p.y >= min(a.y, b.y) - tolerance && p.y <= max(a.y, b.y) + tolerance
    }

    static func intersects(_ a: FloorMeasurementPoint, _ b: FloorMeasurementPoint,
                           _ c: FloorMeasurementPoint, _ d: FloorMeasurementPoint, tolerance: Double) -> Bool {
        let abC = orientation(a, b, c, tolerance: tolerance), abD = orientation(a, b, d, tolerance: tolerance)
        let cdA = orientation(c, d, a, tolerance: tolerance), cdB = orientation(c, d, b, tolerance: tolerance)
        return (abC * abD < 0 && cdA * cdB < 0)
            || (abC == 0 && onSegment(c, a, b, tolerance: tolerance))
            || (abD == 0 && onSegment(d, a, b, tolerance: tolerance))
            || (cdA == 0 && onSegment(a, c, d, tolerance: tolerance))
            || (cdB == 0 && onSegment(b, c, d, tolerance: tolerance))
    }

    /// Winding-number containment explicitly excludes boundary points.
    static func strictlyContains(_ vertices: [FloorMeasurementPoint], _ p: FloorMeasurementPoint,
                                 tolerance: Double) -> Bool {
        var winding = 0
        for i in vertices.indices {
            let a = vertices[i], b = vertices[(i + 1) % vertices.count]
            if onSegment(p, a, b, tolerance: tolerance) { return false }
            if a.y <= p.y && b.y > p.y && orientation(a, b, p, tolerance: tolerance) > 0 { winding += 1 }
            if a.y > p.y && b.y <= p.y && orientation(a, b, p, tolerance: tolerance) < 0 { winding -= 1 }
        }
        return winding != 0
    }

    static func fullyContains(_ outer: [FloorMeasurementPoint], _ inner: [FloorMeasurementPoint]) -> Bool {
        let epsilon = tolerance(outer + inner)
        guard inner.allSatisfy({ strictlyContains(outer, $0, tolerance: epsilon) }) else { return false }
        // Vertices alone are insufficient for a concave boundary: an inner
        // edge can leave and re-enter a notch between two contained corners.
        for i in outer.indices {
            for j in inner.indices {
                if intersects(outer[i], outer[(i + 1) % outer.count], inner[j], inner[(j + 1) % inner.count],
                              tolerance: epsilon) { return false }
            }
        }
        return true
    }

    private static func segmentEntersInterior(_ a: FloorMeasurementPoint, _ b: FloorMeasurementPoint,
                                              of polygon: [FloorMeasurementPoint], tolerance: Double) -> Bool {
        let dx = b.x - a.x, dy = b.y - a.y, lengthSquared = dx * dx + dy * dy
        var cuts = [0.0, 1.0]
        // When boundaries meet exactly at a polygon corner, there may be no
        // proper edge crossing and no vertex strictly inside. Split at every
        // such meeting instead of testing just the complete wall midpoint.
        for point in polygon where onSegment(point, a, b, tolerance: tolerance) {
            let along = ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared
            cuts.append(min(1, max(0, along)))
        }
        cuts.sort()
        for i in cuts.indices.dropLast() where cuts[i + 1] > cuts[i] {
            let midpoint = (cuts[i] + cuts[i + 1]) / 2
            if strictlyContains(polygon, .init(x: a.x + midpoint * dx, y: a.y + midpoint * dy),
                                tolerance: tolerance) { return true }
        }
        return false
    }

    static func interiorsOverlap(_ first: [FloorMeasurementPoint], _ second: [FloorMeasurementPoint]) -> Bool {
        let epsilon = tolerance(first + second)
        if first.contains(where: { strictlyContains(second, $0, tolerance: epsilon) })
            || second.contains(where: { strictlyContains(first, $0, tolerance: epsilon) }) { return true }
        let firstWinding = signedArea(first), secondWinding = signedArea(second)
        for i in first.indices {
            let a = first[i], b = first[(i + 1) % first.count]
            for j in second.indices {
                let c = second[j], d = second[(j + 1) % second.count]
                let abC = orientation(a, b, c, tolerance: epsilon), abD = orientation(a, b, d, tolerance: epsilon)
                let cdA = orientation(c, d, a, tolerance: epsilon), cdB = orientation(c, d, b, tolerance: epsilon)
                if abC * abD < 0 && cdA * cdB < 0 { return true }
                if abC == 0 && abD == 0 {
                    let dx = b.x - a.x, dy = b.y - a.y, length = distance(a, b)
                    let cAlong = ((c.x - a.x) * dx + (c.y - a.y) * dy) / length
                    let dAlong = ((d.x - a.x) * dx + (d.y - a.y) * dy) / length
                    let overlap = min(length, max(cAlong, dAlong)) - max(0, min(cAlong, dAlong))
                    let sameInteriorSide = firstWinding * secondWinding * (dx * (d.x - c.x) + dy * (d.y - c.y)) > 0
                    if overlap > epsilon && sameInteriorSide { return true }
                }
            }
            if segmentEntersInterior(a, b, of: second, tolerance: epsilon) { return true }
        }
        for i in second.indices {
            let a = second[i], b = second[(i + 1) % second.count]
            if segmentEntersInterior(a, b, of: first, tolerance: epsilon) { return true }
        }
        return false
    }
}

struct FloorMeasurementRoom: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    /// Zero is the first floor; negative floors are basements.
    var floor: Int = 0
    var widthMeters: Double
    var lengthMeters: Double
    var heightMeters: Double? = nil
    var xMeters: Double = 0
    var yMeters: Double = 0
    var rotationQuarterTurns: Int = 0
    var source: FloorMeasurementSource = .manual

    var rotatedWidthMeters: Double {
        rotationQuarterTurns % 2 == 0 ? widthMeters : lengthMeters
    }

    var rotatedLengthMeters: Double {
        rotationQuarterTurns % 2 == 0 ? lengthMeters : widthMeters
    }

    var floorName: String { FloorMeasurementPlan.floorName(floor) }

    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.count <= 40,
              name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw FloorMeasurementError.invalidName
        }
        try FloorMeasurementInput.validateDimension(widthMeters)
        try FloorMeasurementInput.validateDimension(lengthMeters)
        if let heightMeters { try FloorMeasurementInput.validateDimension(heightMeters) }
        guard xMeters.isFinite, yMeters.isFinite,
              (-200...200).contains(xMeters), (-200...200).contains(yMeters) else {
            throw FloorMeasurementError.invalidPosition
        }
        guard (-2...20).contains(floor) else { throw FloorMeasurementError.invalidFloor }
        guard (0...3).contains(rotationQuarterTurns) else { throw FloorMeasurementError.invalidRotation }
    }

    /// Rooms are axis-aligned after quarter-turn rotation. Only interior area
    /// counts as overlap; floating point round-off at a shared edge does not.
    func overlaps(_ other: FloorMeasurementRoom) -> Bool {
        guard floor == other.floor else { return false }
        let right = xMeters + rotatedWidthMeters
        let top = yMeters + rotatedLengthMeters
        let otherRight = other.xMeters + other.rotatedWidthMeters
        let otherTop = other.yMeters + other.rotatedLengthMeters
        let scale = max(1, abs(xMeters), abs(yMeters), abs(right), abs(top),
                        abs(other.xMeters), abs(other.yMeters), abs(otherRight), abs(otherTop))
        let tolerance = scale * Double.ulpOfOne * 8
        return min(right, otherRight) - max(xMeters, other.xMeters) > tolerance
            && min(top, otherTop) - max(yMeters, other.yMeters) > tolerance
    }

    func displayDimensions(unit: FloorMeasurementUnit) -> String {
        "\(FloorMeasurementInput.display(rotatedWidthMeters, unit: unit)) × \(FloorMeasurementInput.display(rotatedLengthMeters, unit: unit))"
    }
}

// Defaults for placement/source also apply when a version-one wire room omits
// those optional editing fields. Identity and both measured sides are required.
extension FloorMeasurementRoom {
    enum CodingKeys: String, CodingKey {
        case id, name, floor, widthMeters, lengthMeters, heightMeters
        case xMeters, yMeters, rotationQuarterTurns, source
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        floor = try c.decodeIfPresent(Int.self, forKey: .floor) ?? 0
        widthMeters = try c.decode(Double.self, forKey: .widthMeters)
        lengthMeters = try c.decode(Double.self, forKey: .lengthMeters)
        heightMeters = try c.decodeIfPresent(Double.self, forKey: .heightMeters)
        xMeters = try c.decodeIfPresent(Double.self, forKey: .xMeters) ?? 0
        yMeters = try c.decodeIfPresent(Double.self, forKey: .yMeters) ?? 0
        rotationQuarterTurns = try c.decodeIfPresent(Int.self, forKey: .rotationQuarterTurns) ?? 0
        source = try c.decodeIfPresent(FloorMeasurementSource.self, forKey: .source) ?? .manual
    }
}

struct FloorMeasurementPlan: Codable, Hashable {
    static let wireKey = "floor_measurements_v1"
    static func isPrivateKey(_ key: String) -> Bool {
        key.lowercased().replacingOccurrences(of: "_", with: "").hasPrefix("floormeasurements")
    }
    static func isPlanKey(_ key: String) -> Bool {
        key.lowercased().replacingOccurrences(of: "_", with: "") == "floormeasurementsv1"
    }
    static func wireValue(in details: [String: String]?) -> String? {
        let values = Set((details ?? [:]).filter { isPlanKey($0.key) }.values)
        return values.count == 1 ? values.first : nil
    }
    static func hasUnreadableValue(in details: [String: String]?) -> Bool {
        let values = (details ?? [:]).filter { isPlanKey($0.key) }
        return !values.isEmpty && decodeWireValue(wireValue(in: details)) == nil
    }
    static func replacingWire(in details: [String: String]?, with value: String) -> [String: String] {
        var result = (details ?? [:]).filter { !isPlanKey($0.key) }
        result[wireKey] = value
        return result
    }
    static let maximumRooms = 24
    static let maximumOutlines = 12
    static let maximumWireBytes = 10_000

    var version: Int = 1
    var unit: FloorMeasurementUnit = .feet
    var rooms: [FloorMeasurementRoom] = []
    var outlines: [FloorMeasurementOutline] = []
    var updatedAt = Date()

    var isEmpty: Bool { rooms.isEmpty && outlines.isEmpty }

    var hasOverlaps: Bool {
        for i in rooms.indices {
            for j in rooms.indices where j > i {
                if rooms[i].overlaps(rooms[j]) { return true }
            }
        }
        return false
    }

    /// Sum of entered room areas, not an independently measured building area.
    /// Invalid plans (including overlaps) never contribute a misleading total.
    var totalRoomAreaMeters2: Double {
        guard (try? validate()) != nil else { return 0 }
        return rooms.reduce(0) { $0 + $1.widthMeters * $1.lengthMeters }
    }

    func validate() throws {
        guard version == 1 || version == 2,
              version == 2 || outlines.isEmpty else { throw FloorMeasurementError.unsupportedVersion }
        guard rooms.count <= Self.maximumRooms else { throw FloorMeasurementError.tooManyRooms }
        guard outlines.count <= Self.maximumOutlines else { throw FloorMeasurementError.tooManyOutlines }
        guard updatedAt.timeIntervalSinceReferenceDate.isFinite else { throw FloorMeasurementError.invalidDate }
        var ids = Set<UUID>()
        for room in rooms {
            try room.validate()
            guard ids.insert(room.id).inserted else { throw FloorMeasurementError.duplicateRoom }
        }
        guard !hasOverlaps else { throw FloorMeasurementError.overlappingRooms }
        for outline in outlines {
            try outline.validate()
            guard ids.insert(outline.id).inserted else { throw FloorMeasurementError.duplicateOutline }
        }
        try validateOutlineRelationships()
        guard try wireData().count <= Self.maximumWireBytes else { throw FloorMeasurementError.tooLarge }
    }

    /// Each floor has exactly one area basis. Outlined floors use classified
    /// outlines only; rectangle-only floors retain their entered room areas.
    /// A room inside an outlined floor never increases its worksheet total.
    func worksheet() throws -> [FloorMeasurementWorksheetRow] {
        try validate()
        let outlinedFloors = Set(outlines.map(\.floor))
        var rows = outlines.map { outline in
            let deduction = outlines.filter { $0.deductionFromID == outline.id }.reduce(0) { $0 + $1.areaMeters2 }
            return FloorMeasurementWorksheetRow(id: outline.id, name: outline.name, floor: outline.floor,
                category: outline.category, grossAreaMeters2: outline.areaMeters2,
                deductionAreaMeters2: deduction,
                netAreaMeters2: outline.category == .openBelow ? 0 : max(0, outline.areaMeters2 - deduction),
                perimeterMeters: outline.perimeterMeters, source: outline.source)
        }
        rows += rooms.filter { !outlinedFloors.contains($0.floor) }.map { room in
            let area = room.widthMeters * room.lengthMeters
            return FloorMeasurementWorksheetRow(id: room.id, name: room.name, floor: room.floor,
                category: .finished, grossAreaMeters2: area, deductionAreaMeters2: 0, netAreaMeters2: area,
                perimeterMeters: 2 * (room.widthMeters + room.lengthMeters), source: room.source)
        }
        return rows.sorted {
            if $0.floor != $1.floor { return $0.floor < $1.floor }
            if $0.name != $1.name { return $0.name < $1.name }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private func validateOutlineRelationships() throws {
        let solids = outlines.filter { $0.category != .openBelow }
        let deductions = outlines.filter { $0.category == .openBelow }
        guard solids.allSatisfy({ $0.deductionFromID == nil }) else { throw FloorMeasurementError.invalidDeduction }
        for deduction in deductions {
            guard let parentID = deduction.deductionFromID,
                  let parent = solids.first(where: { $0.id == parentID }),
                  parent.category == .finished, parent.floor == deduction.floor else {
                throw FloorMeasurementError.invalidDeduction
            }
            guard FloorMeasurementPolygon.fullyContains(parent.vertices, deduction.vertices) else {
                throw FloorMeasurementError.deductionOutsideOutline
            }
        }
        for i in solids.indices {
            for j in solids.indices where j > i && solids[i].floor == solids[j].floor {
                if FloorMeasurementPolygon.interiorsOverlap(solids[i].vertices, solids[j].vertices) {
                    throw FloorMeasurementError.overlappingOutlines
                }
            }
        }
        for i in deductions.indices {
            for j in deductions.indices where j > i && deductions[i].floor == deductions[j].floor {
                if FloorMeasurementPolygon.interiorsOverlap(deductions[i].vertices, deductions[j].vertices) {
                    throw FloorMeasurementError.overlappingDeductions
                }
            }
        }
        for parent in solids {
            let deducted = deductions.filter { $0.deductionFromID == parent.id }.reduce(0) { $0 + $1.areaMeters2 }
            guard deducted.isFinite, parent.areaMeters2 - deducted >= 0 else { throw FloorMeasurementError.invalidDeduction }
        }
    }

    func encodedWireValue() throws -> String {
        try validate()
        return String(decoding: try wireData(), as: UTF8.self)
    }

    static func decodeWireValue(_ raw: String?) -> FloorMeasurementPlan? {
        guard let raw, raw.utf8.count <= maximumWireBytes,
              let data = raw.data(using: .utf8),
              let plan = try? JSONDecoder().decode(Self.self, from: data),
              (try? plan.validate()) != nil else { return nil }
        return plan
    }

    static func floorName(_ floor: Int) -> String {
        switch floor {
        case -2: return "Second basement"
        case -1: return "Basement"
        case 0: return "First floor"
        default: return "Floor \(floor + 1)"
        }
    }

    private func wireData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

extension FloorMeasurementPlan {
    enum CodingKeys: String, CodingKey { case version, unit, rooms, outlines, updatedAt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        unit = try c.decode(FloorMeasurementUnit.self, forKey: .unit)
        rooms = try c.decode([FloorMeasurementRoom].self, forKey: .rooms)
        // Version one did not have this key. Version two requires the array so
        // a malformed new payload cannot quietly fall back to stale rectangles.
        outlines = version == 1 ? try c.decodeIfPresent([FloorMeasurementOutline].self, forKey: .outlines) ?? []
            : try c.decode([FloorMeasurementOutline].self, forKey: .outlines)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }
}

struct FloorMeasurementWall: Hashable {
    let floor: Int
    /// Horizontal: y = position, x = start...end. Vertical swaps x and y.
    let horizontal: Bool
    let position: Double
    let start: Double
    let end: Double
    let height: Double
}

enum FloorMeasurementGeometry {
    private struct WallGroup {
        let floor: Int
        let horizontal: Bool
        let position: Double
        var walls: [FloorMeasurementWall]
    }

    /// Shared room edges produce one wall surface. For a partially shared edge,
    /// each interval uses the tallest active room, keeping height changes intact.
    static func walls(for rooms: [FloorMeasurementRoom]) throws -> [FloorMeasurementWall] {
        try FloorMeasurementPlan(rooms: rooms).validate()
        var raw: [FloorMeasurementWall] = []
        for room in rooms {
            let right = room.xMeters + room.rotatedWidthMeters
            let top = room.yMeters + room.rotatedLengthMeters
            let height = room.heightMeters ?? 2.4
            for y in [room.yMeters, top] {
                raw.append(.init(floor: room.floor, horizontal: true, position: y,
                                 start: room.xMeters, end: right, height: height))
            }
            for x in [room.xMeters, right] {
                raw.append(.init(floor: room.floor, horizontal: false, position: x,
                                 start: room.yMeters, end: top, height: height))
            }
        }
        raw.sort {
            if $0.floor != $1.floor { return $0.floor < $1.floor }
            if $0.horizontal != $1.horizontal { return $0.horizontal }
            if $0.position != $1.position { return $0.position < $1.position }
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.end != $1.end { return $0.end < $1.end }
            return $0.height < $1.height
        }
        var groups: [WallGroup] = []
        for wall in raw {
            if let last = groups.last, last.floor == wall.floor,
               last.horizontal == wall.horizontal, near(last.position, wall.position) {
                groups[groups.count - 1].walls.append(wall)
            } else {
                groups.append(.init(floor: wall.floor, horizontal: wall.horizontal,
                                    position: wall.position, walls: [wall]))
            }
        }
        var result: [FloorMeasurementWall] = []
        for group in groups {
            let edges = group.walls.flatMap { [$0.start, $0.end] }.sorted()
            var boundaries: [Double] = []
            for edge in edges {
                if let last = boundaries.last, near(last, edge) { continue }
                boundaries.append(edge)
            }
            for index in boundaries.indices.dropLast() {
                let start = boundaries[index], end = boundaries[index + 1]
                let midpoint = start + (end - start) / 2
                guard let height = group.walls.filter({ $0.start < midpoint && $0.end > midpoint })
                    .map(\.height).max() else { continue }
                if let previous = result.last, previous.floor == group.floor,
                   previous.horizontal == group.horizontal, previous.position == group.position,
                   near(previous.end, start), near(previous.height, height) {
                    result[result.count - 1] = .init(floor: group.floor, horizontal: group.horizontal,
                                                    position: group.position, start: previous.start, end: end,
                                                    height: max(previous.height, height))
                } else {
                    result.append(.init(floor: group.floor, horizontal: group.horizontal,
                                        position: group.position, start: start, end: end, height: height))
                }
            }
        }
        return result
    }

    private static func near(_ a: Double, _ b: Double) -> Bool {
        abs(a - b) <= max(1, abs(a), abs(b)) * Double.ulpOfOne * 8
    }
}

/// Display text may round a valid measurement past a validation boundary.
/// Preserve the original value only while both displayed fields are untouched.
struct FloorMeasurementFieldReference {
    let meters: Double
    let primary: String
    let inches: String

    func resolve(primary: String, inches: String, unit: FloorMeasurementUnit) throws -> Double {
        try FloorMeasurementInput.validateDimension(meters)
        if primary == self.primary && inches == self.inches { return meters }
        return try FloorMeasurementInput.meters(primary: primary, inches: inches, unit: unit)
    }
}

enum FloorMeasurementInput {
    /// Strict numeric entry: grouping, signs, exponents, and unit suffixes are
    /// rejected. A single comma is accepted only as an unambiguous decimal.
    static func meters(primary: String, inches: String = "", unit: FloorMeasurementUnit) throws -> Double {
        let number = try decimal(primary)
        let inchText = inches.trimmingCharacters(in: .whitespacesAndNewlines)
        let inchNumber = inchText.isEmpty ? 0 : try decimal(inchText)
        guard inchNumber < 12 else { throw FloorMeasurementError.invalidInches }
        let meters: Double
        switch unit {
        case .feet: meters = number * 0.3048 + inchNumber * 0.0254
        case .meters:
            guard inchNumber == 0 else { throw FloorMeasurementError.invalidInches }
            meters = number
        }
        try validateDimension(meters)
        return meters
    }

    static func validateDimension(_ meters: Double) throws {
        guard meters.isFinite, (0.1...100).contains(meters) else {
            throw FloorMeasurementError.invalidDimension
        }
    }

    static func display(_ meters: Double, unit: FloorMeasurementUnit) -> String {
        guard meters.isFinite, meters >= 0, meters <= 100 else { return "—" }
        return formattedLength(meters, unit: unit)
    }

    /// An aggregate can exceed one wall's input limit (64 walls × 100 m).
    /// Keep dimension entry validation independent from perimeter display.
    static func displayPerimeter(_ meters: Double, unit: FloorMeasurementUnit) -> String {
        guard meters.isFinite, (0...6_400).contains(meters) else { return "—" }
        return formattedLength(meters, unit: unit)
    }

    private static func formattedLength(_ meters: Double, unit: FloorMeasurementUnit) -> String {
        switch unit {
        case .feet:
            let totalInches = Int((meters / 0.0254).rounded())
            return "\(totalInches / 12)′ \(totalInches % 12)″"
        case .meters:
            let formatter = NumberFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.numberStyle = .decimal
            formatter.usesGroupingSeparator = false
            formatter.maximumFractionDigits = 2
            return "\(formatter.string(from: NSNumber(value: meters)) ?? "—") m"
        }
    }

    private static func decimal(_ input: String) throws -> Double {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 64,
              text.range(of: #"^(?:[0-9]+(?:[.,][0-9]+)?|[.,][0-9]+)$"#, options: .regularExpression) != nil else {
            throw FloorMeasurementError.invalidInput
        }
        if text.contains(",") {
            let parts = text.split(separator: ",", omittingEmptySubsequences: false)
            guard parts.count == 2, !text.contains(".") else { throw FloorMeasurementError.invalidInput }
            // "1,000" could be one or one thousand. Never silently choose.
            if (1...3).contains(parts[0].count), parts[0].first != "0", parts[1].count == 3 {
                throw FloorMeasurementError.invalidInput
            }
        }
        guard let value = Double(text.replacingOccurrences(of: ",", with: ".")), value.isFinite else {
            throw FloorMeasurementError.invalidInput
        }
        return value
    }
}

/// A scalar fact preserves SQL null separately from zero/empty text. Values are
/// encoded as JSON scalars, rather than strings that the server must guess at.
indirect enum ListingFactValue: Codable, Hashable {
    case null, text(String), number(Double), boolean(Bool)
    case object([String: ListingFactValue]), array([ListingFactValue])
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let s = try? c.decode(String.self) { self = .text(s) }
        else if let b = try? c.decode(Bool.self) { self = .boolean(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let o = try? c.decode([String: ListingFactValue].self) { self = .object(o) }
        else { self = .array(try c.decode([ListingFactValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .text(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .boolean(let b): try c.encode(b)
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        }
    }
    var json: Any {
        switch self {
        case .null: return NSNull(); case .text(let s): return s; case .number(let n): return n
        case .boolean(let b): return b; case .object(let o): return o.mapValues(\.json); case .array(let a): return a.map(\.json)
        }
    }
}
struct ListingFactEdit: Codable, Hashable {
    var expected: ListingFactValue
    var value: ListingFactValue
    /// Detail-key absence differs from an existing JSON null.
    var expectedPresent: Bool? = nil
}
struct ListingFactsSyncState: Codable, Hashable {
    var baseline: [String: ListingFactValue] = [:]
    var detailBaseline: [String: ListingFactValue] = [:]
    var fields: [String: ListingFactEdit] = [:]
    var details: [String: ListingFactEdit] = [:]
    var conflict = false
    var reviewRequired = false
    var hasChanges: Bool { !fields.isEmpty || !details.isEmpty }
}
struct ListingFactsReview {
    let local: Listing
    let shared: Listing
    let ownerID: String?
    let sessionRevision: UInt64
}
enum ListingFactsSyncError: LocalizedError {
    case reviewRequired, conflict
    var errorDescription: String? {
        switch self {
        case .reviewRequired: return "Your older listing edits are saved on this iPhone. Review the shared details before syncing them."
        case .conflict: return "Listing details changed elsewhere. Your edits are safe on this iPhone. Review both versions before saving."
        }
    }
}
enum ListingFactsSync {
    static var editableDetailKeys: Set<String> {
        Set(SpaceType.allCases.flatMap { $0.detailFields.map(\.key) }).union([Listing.searchIndexingKey])
    }
    static func values(_ l: Listing) -> [String: ListingFactValue] {
        func text(_ s: String?) -> ListingFactValue {
            let s = s?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return s.isEmpty ? .null : .text(s)
        }
        func positive(_ n: Double) -> ListingFactValue { n > 0 ? .number(n) : .null }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let lat = l.latitude.flatMap { $0.isFinite ? ListingFactValue.number(($0 * 1000).rounded() / 1000) : nil } ?? .null
        let lng = l.longitude.flatMap { $0.isFinite ? ListingFactValue.number(($0 * 1000).rounded() / 1000) : nil } ?? .null
        let rawURL = l.zillowURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let zillow = rawURL.isEmpty ? nil : (rawURL.lowercased().hasPrefix("https://") || rawURL.lowercased().hasPrefix("http://") ? rawURL : "https://" + rawURL)
        return ["space_type": .text(l.spaceType.rawValue), "address": .text(l.address),
                "beds": positive(Double(l.beds)), "baths": positive((l.baths * 10).rounded() / 10), "sqft": positive(Double(l.sqft)),
                "price_cents": positive(Double(l.price.cents)), "tagline": text(l.tagline),
                "zillow_url": text(zillow), "lat": lat, "lng": lng,
                "sold_at": l.soldAt.map { .text(f.string(from: $0)) } ?? .null]
    }
    static func detailValues(_ l: Listing) -> [String: String] {
        var d = (l.details ?? [:]).filter { editableDetailKeys.contains($0.key) }
        if let allow = l.allowSearchIndexing { d[Listing.searchIndexingKey] = allow ? "true" : "false" }
        return d
    }
    static func detailFacts(_ l: Listing) -> [String: ListingFactValue] {
        detailValues(l).mapValues(ListingFactValue.text)
    }
    static func stage(from previous: Listing, in current: inout Listing, expectedBase: Listing? = nil) {
        var state = previous.factsSync ?? ListingFactsSyncState()
        // A flag from an older binary cannot identify which values were edited.
        if previous.serverID != nil && previous.needsServerSync == true && previous.factsSync == nil {
            state.reviewRequired = true
        }
        let old = values(previous), new = values(current)
        var keys = Set(old.keys).filter { old[$0] != new[$0] }
        if keys.contains("lat") || keys.contains("lng") { keys.formUnion(["lat", "lng"]) }
        for key in keys {
            let expected: ListingFactValue
            if let base = expectedBase {
                expected = base.factsSync?.fields[key]?.expected ?? base.factsSync?.baseline[key] ?? values(base)[key] ?? .null
            } else { expected = state.fields[key]?.expected ?? state.baseline[key] ?? old[key] ?? .null }
            state.fields[key] = ListingFactEdit(expected: expected, value: new[key] ?? .null)
        }
        // Clearing a sold marker deliberately restores a Studio-archived home.
        // Other local render/status changes never become ordinary edit intent.
        if previous.isInactive, !current.isInactive,
           previous.factsSync?.baseline["status"] == .text("archived") {
            state.fields["status"] = ListingFactEdit(expected: .text("archived"), value: .text("ready"))
        }
        let oldDetails = detailValues(previous), newDetails = detailValues(current)
        for key in Set(oldDetails.keys).union(newDetails.keys) where oldDetails[key] != newDetails[key] {
            let baseline = state.baseline.isEmpty ? oldDetails[key].map(ListingFactValue.text) : state.detailBaseline[key]
            let prior = state.details[key]
            let cached = expectedBase.map { $0.factsSync?.detailBaseline ?? detailFacts($0) }
            let expected = expectedBase?.factsSync?.details[key]?.expected ?? (cached != nil ? cached?[key] ?? .null : prior?.expected ?? baseline ?? .null)
            let present = expectedBase?.factsSync?.details[key]?.expectedPresent ?? (cached != nil ? cached?[key] != nil : prior?.expectedPresent ?? (baseline != nil))
            state.details[key] = ListingFactEdit(expected: expected, value: newDetails[key].map(ListingFactValue.text) ?? .null,
                                               expectedPresent: present)
        }
        current.factsSync = state
        current.needsServerSync = state.hasChanges || state.reviewRequired || (current.serverID == nil && current.needsServerSync == true)
    }
    static func body(_ l: Listing) throws -> [String: Any] {
        guard let state = l.factsSync, !state.reviewRequired else { throw ListingFactsSyncError.reviewRequired }
        guard !state.conflict else { throw ListingFactsSyncError.conflict }
        guard state.hasChanges else { throw ListingFactsSyncError.reviewRequired }
        return ["expected": state.fields.mapValues { $0.expected.json }, "changes": state.fields.mapValues { $0.value.json },
                "details_expected": state.details.mapValues { ["present": $0.expectedPresent ?? ($0.expected != .null), "value": $0.expected.json] },
                "details_changes": state.details.mapValues { $0.value.json }]
    }
    static func acknowledge(submitted: Listing, receipt: Listing, current: inout Listing) {
        guard var state = current.factsSync else { return }
        let received = receipt.factsSync?.baseline ?? values(receipt)
        let receivedDetails = receipt.factsSync?.detailBaseline ?? detailFacts(receipt)
        for (key,sent) in submitted.factsSync?.fields ?? [:] {
            guard received[key] == sent.value else { continue }
            if state.fields[key]?.value == sent.value { state.fields.removeValue(forKey: key) }
            else { state.fields[key]?.expected = sent.value }
        }
        for (key,sent) in submitted.factsSync?.details ?? [:] {
            guard (receivedDetails[key] ?? .null) == sent.value,
                  sent.value != .null || receivedDetails[key] == nil else { continue }
            if state.details[key]?.value == sent.value { state.details.removeValue(forKey: key) }
            else { state.details[key]?.expected = sent.value; state.details[key]?.expectedPresent = receivedDetails[key] != nil }
        }
        // Location is one edit. A mid-request change to either endpoint must
        // retain the pair, using the acknowledged coordinates as its base.
        if state.fields["lat"] != nil || state.fields["lng"] != nil {
            let local = values(current)
            for key in ["lat", "lng"] where state.fields[key] == nil {
                state.fields[key] = ListingFactEdit(expected: received[key] ?? .null, value: local[key] ?? .null)
            }
        }
        state.baseline = received; state.detailBaseline = receivedDetails
        current.factsSync = state
        current.needsServerSync = state.hasChanges || state.reviewRequired
        // Keep pending geometry and filenames while adopting untouched office facts.
        if current.needsServerSync != true { FloorMeasurementSync.adoptFacts(from: receipt, current: &current) }
    }
    static func hasSameLineage(_ snapshot: Listing, _ current: Listing) -> Bool {
        guard let submitted = snapshot.factsSync, let state = current.factsSync,
              !state.reviewRequired, !state.conflict else { return false }
        return submitted.fields.allSatisfy { state.fields[$0.key]?.expected == $0.value.expected } &&
            submitted.details.allSatisfy { state.details[$0.key]?.expected == $0.value.expected }
    }
}

struct FloorMeasurementSyncState: Codable, Hashable {
    var expected: String? = nil
    var pending = false
    var conflict = false
    var savedLocalCopy: String? = nil
    /// Older snapshots cannot prove whether generic dirty state also contains
    /// ordinary edits. Preserve them and require an explicit choice before PATCH.
    var factsReviewRequired: Bool? = nil
}

enum FloorMeasurementSync {
    static func recoverLegacyPending(in listing: inout Listing) {
        guard listing.serverID != nil, listing.needsServerSync == true,
              listing.measurementSync == nil, let plan = listing.floorMeasurements else { return }
        let value = try? plan.encodedWireValue()
        let unreadable = FloorMeasurementPlan.hasUnreadableValue(in: listing.details) || value == nil
        listing.measurementSync = FloorMeasurementSyncState(
            expected: FloorMeasurementPlan.wireValue(in: listing.details), pending: true,
            conflict: unreadable, factsReviewRequired: true)
        // Never choose between conflicting aliases or erase an unknown format.
        if !unreadable, let value { listing.details = FloorMeasurementPlan.replacingWire(in: listing.details, with: value) }
    }
    static func stage(_ plan: FloorMeasurementPlan, in listing: inout Listing) throws {
        var state = listing.measurementSync ?? FloorMeasurementSyncState(
            expected: FloorMeasurementPlan.wireValue(in: listing.details))
        guard !state.conflict else { throw FloorMeasurementSyncError.conflict }
        let value = try plan.encodedWireValue()
        listing.floorMeasurements = plan
        listing.details = FloorMeasurementPlan.replacingWire(in: listing.details, with: value)
        state.pending = true
        listing.measurementSync = state
    }
    static func adoptFacts(from receipt: Listing, current: inout Listing) {
        guard current.needsServerSync != true else { return }
        let local = FloorMeasurementPlan.wireValue(in: current.details)
        current.address = receipt.address; current.beds = receipt.beds; current.baths = receipt.baths
        current.sqft = receipt.sqft; current.price = receipt.price; current.tagline = receipt.tagline
        current.soldAt = receipt.soldAt; current.status = receipt.status; current.cloudArchived = receipt.cloudArchived
        current.zillowURL = receipt.zillowURL; current.latitude = receipt.latitude; current.longitude = receipt.longitude
        current.spaceTypeRaw = receipt.spaceTypeRaw; current.allowSearchIndexing = receipt.allowSearchIndexing
        current.factsSync = receipt.factsSync
        current.details = receipt.details
        if current.measurementSync?.pending == true, let local {
            current.details = FloorMeasurementPlan.replacingWire(in: current.details, with: local)
        } else { current.floorMeasurements = receipt.floorMeasurements }
    }
    static func acknowledge(submitted: Listing, receipt: Listing, current: inout Listing) {
        let sent = FloorMeasurementPlan.wireValue(in: submitted.details)
        let accepted = FloorMeasurementPlan.wireValue(in: receipt.details)
        guard sent == accepted else { return }
        var state = current.measurementSync ?? FloorMeasurementSyncState()
        state.expected = accepted
        state.pending = FloorMeasurementPlan.wireValue(in: current.details) != sent
        state.conflict = false
        current.measurementSync = state
    }
}
enum FloorMeasurementSyncError: LocalizedError {
    case conflict
    var errorDescription: String? {
        "Measurements changed on another device. Your local copy is safe. Load the shared version to continue."
    }
}
