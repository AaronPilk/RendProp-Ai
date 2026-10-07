import Foundation
import CryptoKit

/// Desktop and iPhone share server IDs. Device filenames and pending edits remain
/// local until their existing upload/write operation has completed.
protocol WorkspaceSyncAPI {
    func cloudListings() async throws -> [Listing]
    func cloudListingState(listingID: UUID, orgID: UUID, offset: Int) async throws -> CloudListingState
    func cloudMedia(listingID: UUID, orgID: UUID, offset: Int) async throws -> CloudMediaPage
    func cloudBrand() async throws -> CloudBrand
    func cloudCreative(listingID: UUID, orgID: UUID) async throws -> CloudCreative
    func cloudNativeReel(listingID: UUID, orgID: UUID) async throws -> CloudNativeReelDocument?
    func saveCloudNativeReel(_ draft: NativeReelDraft, listingID: UUID, orgID: UUID, revision: Int) async throws -> CloudNativeReelDocument
}

/// Only explicitly reviewed public contact fields; never login email or workspace brand.
struct PersonalCardReceipt: Codable, Equatable, Sendable {
    let ok: Bool
    let userID: UUID
    let spaceType: String?
    let publicCard: [String: String]?
    enum CodingKeys: String, CodingKey { case ok; case userID = "user_id", spaceType = "space_type", publicCard = "public_card" }
    init(ok: Bool, userID: UUID, spaceType: String?, publicCard: [String: String]?) {
        self.ok = ok; self.userID = userID; self.spaceType = spaceType; self.publicCard = publicCard
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // An old GET /me response must not masquerade as an empty card receipt.
        guard c.contains(.spaceType), c.contains(.publicCard) else { throw CloudSyncError.invalidResponse }
        ok = try c.decode(Bool.self, forKey: .ok); userID = try c.decode(UUID.self, forKey: .userID)
        spaceType = try c.decodeIfPresent(String.self, forKey: .spaceType)
        publicCard = try c.decodeIfPresent([String: String].self, forKey: .publicCard)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ok, forKey: .ok); try c.encode(userID, forKey: .userID)
        try c.encode(spaceType, forKey: .spaceType); try c.encode(publicCard, forKey: .publicCard)
    }
    func checked(owner: UUID) throws -> Self {
        let limits = ["name":120,"title":120,"brokerage":160,"phone":80,"email":254,"website":2048,"instagram":500,"linkedin":500,"tiktok":500]
        guard ok, userID == owner, spaceType == nil || SpaceType(rawValue: spaceType!) != nil,
              publicCard?.allSatisfy({ key, value in
                  guard let limit = limits[key], value.count <= limit else { return false }
                  return !value.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
              }) ?? true else { throw CloudSyncError.invalidResponse }
        return self
    }
    func expectedWire(keys: [String]) -> [String: Any] {
        Dictionary(uniqueKeysWithValues: keys.map { key in
            let value = key == "space_type" ? spaceType : publicCard?[key]
            return (key, value.map { ["present": true, "value": $0] as [String: Any] } ?? ["present": false])
        })
    }
}

struct CloudBrand {
    let userID: UUID
    let orgID: UUID
    let spaceType: String
    let fields: [String: String]
    var personalCard: PersonalCardReceipt? = nil
}

/// One details envelope is used for both writes and draft replay detection.
/// A nil typed plan preserves an unknown/invalid wire value. Explicit removal
/// must also remove its raw key, or save an empty supported plan.
enum ListingWireDetails {
    static let maxBytes = 16_000

    enum ValidationError: LocalizedError {
        case tooLarge
        var errorDescription: String? {
            "The listing details and measurements are too large to sync. Shorten the details and try again."
        }
    }

    static func merged(_ listing: Listing) throws -> [String: String] {
        var details = listing.details ?? [:]
        if let plan = listing.floorMeasurements {
            details = FloorMeasurementPlan.replacingWire(in: details, with: try plan.encodedWireValue())
        }
        if let allow = listing.allowSearchIndexing {
            details[Listing.searchIndexingKey] = allow ? "true" : "false"
        }
        // The server bounds JSON.stringify(details) to 16,000 characters.
        // Bounding UTF-8 bytes is conservative for its UTF-16 length check and
        // includes escaping/envelope overhead rather than only the inner plan.
        let encoded = try JSONSerialization.data(withJSONObject: details, options: [.sortedKeys, .withoutEscapingSlashes])
        guard encoded.count <= maxBytes else { throw ValidationError.tooLarge }
        return details
    }
}

/// The actual asynchronous create handoff used by AppModel. Tests can suspend
/// its create closure to exercise edits, deletion and account changes in flight.
@MainActor enum CloudDraftCreation {
    struct Identity: Equatable { let userID: String?; let revision: UInt64 }
    static func fingerprint(_ listing: Listing) throws -> String {
        try fingerprintFacts(listing, details: ListingWireDetails.merged(listing))
    }
    static func factsFingerprint(_ listing: Listing) throws -> String {
        try fingerprintFacts(listing, details: ListingWireDetails.merged(listing).filter {
            !FloorMeasurementPlan.isPrivateKey($0.key)
        })
    }
    static func prepare(_ listing: inout Listing) throws {
        // Capture both from the same first request. A retry cannot reconstruct
        // the original ordinary facts from today's potentially edited draft.
        guard listing.cloudCreateFingerprint == nil else { return }
        listing.cloudCreateFingerprint = try fingerprint(listing)
        listing.cloudCreateFactsFingerprint = try factsFingerprint(listing)
    }
    private static func fingerprintFacts(_ listing: Listing, details: [String: String]) throws -> String {
        let facts: [String: Any] = ["address": listing.address, "space": listing.spaceType.rawValue,
            "beds": listing.beds, "baths": listing.baths, "sqft": listing.sqft, "price": listing.price.cents,
            "tagline": listing.tagline ?? "", "details": details, "zillow": listing.zillowURL ?? "",
            "lat": listing.latitude as Any? ?? NSNull(), "lng": listing.longitude as Any? ?? NSNull(),
            "sold": listing.soldAt?.timeIntervalSince1970 as Any? ?? NSNull(), "indexing": listing.allowSearchIndexing as Any? ?? NSNull()]
        let data = try JSONSerialization.data(withJSONObject: facts, options: [.sortedKeys])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func matchesFingerprint(_ listing: Listing, original: String) throws -> Bool {
        if try fingerprint(listing) == original { return true }
        // Prior snapshots hashed raw details. That remains safe only while the
        // typed plan adds no independent edit; otherwise the old hash would
        // overlook a measurement made while the create request was in flight.
        guard listing.floorMeasurements == nil || listing.floorMeasurements ==
                FloorMeasurementPlan.decodeWireValue(listing.details?[FloorMeasurementPlan.wireKey]) else { return false }
        return try fingerprintFacts(listing, details: listing.details ?? [:]) == original
    }
    static func canAutoSync(_ listing: Listing, userID: UUID) -> Bool {
        !listing.isSample && listing.cloudUnavailable != true && listing.cloudDetachedServerID == nil &&
            (listing.cloudSyncOwnerID == nil || listing.cloudSyncOwnerID == userID)
    }
    static func ensure(snapshot: Listing, identity: Identity,
                       create: (Listing) async throws -> Listing,
                       current: () -> Listing?, activeIdentity: () -> Identity,
                       save: (Listing) -> Void, deleteRemoved: (UUID) async -> Void) async throws -> UUID {
        let created = try await create(snapshot)
        if let intended = snapshot.cloudDraftOrgID, created.serverOrgID != intended { throw CloudSyncError.invalidResponse }
        try Task.checkCancellation()
        guard activeIdentity() == identity else { throw CloudSyncError.identityChanged }
        guard var latest = current() else {
            await deleteRemoved(created.serverID ?? created.id)
            throw CancellationError()
        }
        if let existing = latest.serverID { return existing }
        let unchanged = try snapshot.cloudCreateFingerprint.map { try matchesFingerprint(latest, original: $0) } ?? false
        let factsUnchanged = try snapshot.cloudCreateFactsFingerprint.map { try factsFingerprint(latest) == $0 } ?? false
        if !unchanged, latest.measurementSync == nil, let plan = latest.floorMeasurements {
            try FloorMeasurementSync.stage(plan, in: &latest)
        }
        // Preserve device files and bind once. Measurement edits use their own
        // CAS queue; they must never cause a stale ordinary-facts PATCH.
        latest.serverID = created.serverID ?? created.id
        latest.serverOrgID = created.serverOrgID
        latest.cloudSyncOwnerID = identity.userID.flatMap(UUID.init(uuidString:))
        latest.cloudDetachedServerID = nil
        latest.cloudUnavailable = false
        if created.cloudCreateReplayed == true, unchanged {
            // A receipt was lost and the office has since edited the row.
            // With no newer phone edit, adopt those facts instead of PATCHing
            // the old create payload back over the office's work.
            latest.address = created.address; latest.beds = created.beds; latest.baths = created.baths
            latest.sqft = created.sqft; latest.price = created.price; latest.tagline = created.tagline
            latest.details = created.details; latest.zillowURL = created.zillowURL; latest.soldAt = created.soldAt
            latest.status = created.status; latest.cloudArchived = created.cloudArchived
            latest.floorMeasurements = created.floorMeasurements
            latest.measurementSync = created.measurementSync
            latest.latitude = created.latitude; latest.longitude = created.longitude
            latest.spaceTypeRaw = created.spaceTypeRaw; latest.allowSearchIndexing = created.allowSearchIndexing
            latest.factsSync = created.factsSync
            latest.needsServerSync = false
        } else if factsUnchanged {
            latest.needsServerSync = false
            FloorMeasurementSync.adoptFacts(from: created, current: &latest)
        } else {
            latest.needsServerSync = true
            if created.cloudCreateReplayed == true, snapshot.cloudCreateFactsFingerprint == nil,
               latest.measurementSync?.pending == true {
                // An old combined hash cannot distinguish a geometry edit from
                // ordinary edits. Keep both locally until the person chooses.
                latest.measurementSync?.factsReviewRequired = true
            }
        }
        if latest.measurementSync?.pending == true {
            // Creation included the snapshot plan; acknowledge only that exact value.
            FloorMeasurementSync.acknowledge(submitted: snapshot, receipt: created, current: &latest)
        }
        latest.cloudCreateFingerprint = nil; latest.cloudCreateFactsFingerprint = nil; latest.cloudCreateReplayed = nil
        if created.cloudCreateReplayed == true, !factsUnchanged, var intent = latest.factsSync, intent.hasChanges {
            // A replay returns today's row, not the first create's receipt.
            // Retire pre-create intent against the exact first payload only
            // while its persisted fingerprint still proves that snapshot.
            if let original = snapshot.cloudCreateFactsFingerprint,
               try factsFingerprint(snapshot) == original {
                var first = ListingFactsSync.values(snapshot)
                // Match the POST body, including its unrounded baths, raw URL
                // text and the requirement to send coordinates as one pair.
                first["baths"] = snapshot.baths > 0 ? .number(snapshot.baths) : .null
                let firstURL = snapshot.zillowURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                first["zillow_url"] = firstURL.isEmpty ? .null : .text(firstURL)
                first["status"] = .text("draft") // POST omits status; a fresh row starts as draft.
                if snapshot.latitude?.isFinite != true || snapshot.longitude?.isFinite != true {
                    first["lat"] = .null; first["lng"] = .null
                }
                let firstDetails = try ListingWireDetails.merged(snapshot)
                let phone = latest
                let locationKeys = ["lat", "lng"]
                let newerLocation = locationKeys.contains { key in
                    intent.fields[key].map { $0.value != (first[key] ?? .null) } ?? false
                }
                for key in Array(intent.fields.keys) {
                    guard let sent = intent.fields[key] else { continue }
                    if sent.value == (first[key] ?? .null), !(newerLocation && locationKeys.contains(key)) {
                        intent.fields.removeValue(forKey: key)
                    } else { intent.fields[key]?.expected = first[key] ?? .null }
                }
                if newerLocation {
                    let phoneValues = ListingFactsSync.values(phone)
                    for key in locationKeys {
                        intent.fields[key] = ListingFactEdit(expected: first[key] ?? .null,
                            value: intent.fields[key]?.value ?? phoneValues[key] ?? .null)
                    }
                }
                for key in Array(intent.details.keys) {
                    let value = firstDetails[key].map(ListingFactValue.text) ?? .null
                    if intent.details[key]?.value == value { intent.details.removeValue(forKey: key) }
                    else {
                        intent.details[key]?.expected = value
                        intent.details[key]?.expectedPresent = firstDetails[key] != nil
                    }
                }
                // Adopt office facts where the first create consumed the phone
                // edit, then restore only newer pending phone facts and details.
                latest.needsServerSync = false
                FloorMeasurementSync.adoptFacts(from: created, current: &latest)
                for key in intent.fields.keys {
                    switch key {
                    case "address": latest.address = phone.address
                    case "space_type": latest.spaceTypeRaw = phone.spaceTypeRaw
                    case "beds": latest.beds = phone.beds
                    case "baths": latest.baths = phone.baths
                    case "sqft": latest.sqft = phone.sqft
                    case "price_cents": latest.price = phone.price
                    case "tagline": latest.tagline = phone.tagline
                    case "zillow_url": latest.zillowURL = phone.zillowURL
                    case "lat": latest.latitude = phone.latitude
                    case "lng": latest.longitude = phone.longitude
                    case "sold_at": latest.soldAt = phone.soldAt
                    case "status": latest.status = phone.status; latest.cloudArchived = phone.cloudArchived
                    default: break
                    }
                }
                let phoneDetails = ListingFactsSync.detailValues(phone)
                for key in intent.details.keys {
                    if let value = phoneDetails[key] { latest.details = (latest.details ?? [:]).merging([key: value]) { _, phone in phone } }
                    else { latest.details?.removeValue(forKey: key) }
                    if key == Listing.searchIndexingKey { latest.allowSearchIndexing = phone.allowSearchIndexing }
                }
                if phone.measurementSync?.pending == true {
                    latest.floorMeasurements = phone.floorMeasurements
                    latest.measurementSync = phone.measurementSync
                    var details = (latest.details ?? [:]).filter { !FloorMeasurementPlan.isPrivateKey($0.key) }
                    for (key, value) in phone.details ?? [:] where FloorMeasurementPlan.isPrivateKey(key) { details[key] = value }
                    latest.details = details.isEmpty ? nil : details
                } else {
                    latest.measurementSync = created.measurementSync
                }
                latest.needsServerSync = intent.hasChanges || intent.reviewRequired
            } else { intent.reviewRequired = true }
            latest.factsSync = intent
        }
        if latest.factsSync == nil {
            latest.factsSync = created.factsSync
            if latest.needsServerSync == true { latest.factsSync?.reviewRequired = true }
        } else {
            ListingFactsSync.acknowledge(submitted: snapshot, receipt: created, current: &latest)
        }
        save(latest)
        return latest.serverID!
    }
}

/// A media response and its later import keep the original signed-in account,
/// session and selected workspace. URL parsing alone never authorizes a read.
struct CloudMediaAccessContext: Equatable {
    let actorID: UUID
    let revision: UInt64
    let orgID: UUID
    @MainActor static func capture(orgID: UUID) throws -> Self {
        guard AuthStore.shared.isIdentified, let raw = AuthStore.shared.userID,
              let actor = UUID(uuidString: raw), WorkspaceContext.selectedOrgID == orgID else {
            throw CloudSyncError.identityChanged
        }
        return Self(actorID: actor, revision: AuthStore.shared.syncSessionRevision, orgID: orgID)
    }
    @MainActor func check() throws {
        guard AuthStore.shared.isIdentified,
              AuthStore.shared.userID.flatMap(UUID.init(uuidString:)) == actorID,
              AuthStore.shared.syncSessionRevision == revision,
              WorkspaceContext.selectedOrgID == orgID else { throw CloudSyncError.identityChanged }
    }
}

struct CloudCreative {
    struct Result: Decodable, Identifiable {
        struct Word: Codable { let text: String; let start: Double; let end: Double }
        let id: UUID
        let listing_id: UUID
        let kind: String
        let state: String
        let label: String
        let disclosure: String?
        let url: URL?
        let expires_at: String?
        let duration_s: Double?
        let voice_name: String?
        let words: [Word]
    }
    let script: String
    let results: [Result]
}

struct CloudListingState: Decodable {
    struct Published: Decodable {
        let id: UUID
        let listing_id: UUID
        let slug: String?
        let published_at: String?
        let duration_s: Double?
    }
    struct Chapter: Decodable { let asset_id: UUID; let label: String; let t_ms: Int; let sort: Int }
    struct Photo: Decodable { let id: UUID; let listing_id: UUID; let original_key: String?; let enhanced_key: String?; let is_staged: Bool }
    let org_id: UUID
    let listing_id: UUID
    let renders: [Published]
    let photos: [Photo]
    let chapters: [Chapter]
    let next_offset: Int?

    func checked(listingID: UUID, orgID: UUID, offset: Int) throws -> Self {
        guard listing_id == listingID, org_id == orgID, renders.count <= 100, photos.count <= 100,
              renders.allSatisfy({ $0.listing_id == listingID }), photos.allSatisfy({ $0.listing_id == listingID &&
                  !CloudListingMerge.isContactPhotoKey($0.original_key) && !CloudListingMerge.isContactPhotoKey($0.enhanced_key) }),
              next_offset == nil || (next_offset == offset + 100 && offset < 10000)
        else { throw CloudSyncError.invalidResponse }
        return self
    }
    var latestPublished: Published? {
        renders.filter { r in
            guard let published = r.published_at, CloudListingMerge.date(published) != nil,
                  let slug = r.slug, slug.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil else { return false }
            return true
        }.max { (CloudListingMerge.date($0.published_at!) ?? .distantPast) < (CloudListingMerge.date($1.published_at!) ?? .distantPast) }
    }
}

struct CloudMediaPage: Decodable {
    struct Photo: Decodable, Identifiable {
        let id: UUID
        let listing_id: UUID
        let url: URL
        let expires_at: String
        let caption: String?
        let is_staged: Bool
        let is_altered: Bool?
        /// Optional on older servers. Never use the altered result as an original.
        let original_url: URL?
    }
    struct Video: Decodable, Identifiable {
        let id: UUID
        let listing_id: UUID
        let url: URL
        let expires_at: String
        let duration_s: Double?
        let created_at: String
    }
    let org_id: UUID
    let listing_id: UUID
    let photos: [Photo]
    let videos: [Video]
    let next_offset: Int?
    let unavailable_count: Int

    func checked(listingID: UUID, orgID: UUID, offset: Int, now: Date = Date(), actorID: UUID? = nil) throws -> Self {
        guard org_id == orgID, listing_id == listingID, photos.count <= 100, videos.count <= 100,
              unavailable_count >= 0, next_offset == nil || (next_offset == offset + 50 && offset < 10000),
              Set(photos.map(\.id)).count == photos.count, Set(videos.map(\.id)).count == videos.count else { throw CloudSyncError.invalidResponse }
        for photo in photos {
            guard photo.listing_id == listingID else { throw CloudSyncError.invalidResponse }
            try CloudListingMerge.validateMedia(photo.url, expiry: photo.expires_at, listingID: listingID, orgID: orgID, now: now, actorID: actorID)
            if let original = photo.original_url { try CloudListingMerge.validateMedia(original, expiry: photo.expires_at, listingID: listingID, orgID: orgID, now: now, actorID: actorID) }
        }
        for video in videos {
            guard video.listing_id == listingID else { throw CloudSyncError.invalidResponse }
            try CloudListingMerge.validateMedia(video.url, expiry: video.expires_at, listingID: listingID, orgID: orgID, now: now, actorID: actorID)
        }
        return self
    }
}

enum CloudSyncError: LocalizedError {
    case invalidResponse, identityChanged, incomplete, expired, cloudMissing
    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Rendprop couldn't read this cloud update. Pull to refresh and try again."
        case .identityChanged: return "The account or workspace changed while syncing. Refresh from your current workspace."
        case .incomplete: return "The cloud library changed while loading. Your saved work is safe; pull to refresh again."
        case .expired: return "This private file link expired. Refresh the cloud files and try again."
        case .cloudMissing: return "This listing was removed from the cloud or your team access changed. Your files on this iPhone are still available."
        }
    }
}

enum CloudListingMerge {
    static func isContactPhotoKey(_ key: String?) -> Bool {
        guard let key else { return false }
        return key.split(separator: "/").last.map { $0.lowercased().hasPrefix("contact-") } ?? false
    }
    /// The remote input must be the COMPLETE, identity-checked set from the RLS
    /// read. Never call with one page or with a failed/empty fallback response.
    static func merge(local: [Listing], remote: [Listing], protected: Set<UUID>, ownerID: UUID? = nil) throws -> [Listing] {
        guard Set(remote.compactMap(\.serverID)).count == remote.count,
              remote.allSatisfy({ !$0.isSample && $0.serverID != nil && $0.serverOrgID != nil }) else { throw CloudSyncError.invalidResponse }
        let remoteByID = Dictionary(uniqueKeysWithValues: remote.map { ($0.serverID!, $0) })
        var seen = Set<UUID>()
        var result: [Listing] = []
        for var existing in local {
            FloorMeasurementSync.recoverLegacyPending(in: &existing)
            let detached = ownerID != nil && existing.cloudSyncOwnerID == ownerID ? existing.cloudDetachedServerID : nil
            guard !existing.isSample, let sid = existing.serverID ?? detached else { result.append(existing); continue }
            guard seen.insert(sid).inserted else { throw CloudSyncError.invalidResponse }
            guard let fresh = remoteByID[sid] else {
                if protected.contains(existing.id) { result.append(existing); continue }
                // Device-only files are never deleted because a remote row is missing.
                // Keep its local record visible with recovery guidance, but stop writes.
                var missing = existing
                missing.cloudUnavailable = true
                missing.shareSlug = nil; missing.shareURL = nil; missing.unbrandedShareURL = nil; missing.publishedRenderID = nil
                missing.lastError = CloudSyncError.cloudMissing.localizedDescription
                result.append(missing)
                continue
            }
            var merged = existing
            merged.serverID = sid
            merged.serverOrgID = fresh.serverOrgID
            merged.cloudSyncOwnerID = ownerID ?? existing.cloudSyncOwnerID
            merged.cloudDetachedServerID = nil
            merged.cloudUnavailable = false
            if existing.cloudUnavailable == true { merged.lastError = nil }
            // The most recent dirty state is checked at APPLY time, not at fetch
            // start, so typing while a foreground read runs cannot lose an edit.
            if existing.needsServerSync != true && !protected.contains(existing.id) {
                merged.address = fresh.address; merged.beds = fresh.beds; merged.baths = fresh.baths
                merged.sqft = fresh.sqft; merged.price = fresh.price; merged.tagline = fresh.tagline
                merged.details = fresh.details; merged.spaceTypeRaw = fresh.spaceTypeRaw
                if existing.measurementSync?.pending == true {
                    // Adopt unrelated remote facts while retaining the unsynced plan and its CAS base.
                    if let raw = FloorMeasurementPlan.wireValue(in: existing.details) {
                        merged.details = FloorMeasurementPlan.replacingWire(in: merged.details, with: raw)
                    }
                } else {
                    merged.floorMeasurements = fresh.floorMeasurements
                    var state = fresh.measurementSync ?? FloorMeasurementSyncState(
                        expected: FloorMeasurementPlan.wireValue(in: fresh.details))
                    state.savedLocalCopy = existing.measurementSync?.savedLocalCopy
                    merged.measurementSync = state
                }
                merged.soldAt = fresh.soldAt; merged.zillowURL = fresh.zillowURL
                merged.latitude = fresh.latitude; merged.longitude = fresh.longitude
                merged.allowSearchIndexing = fresh.allowSearchIndexing
                merged.status = fresh.status; merged.cloudArchived = fresh.cloudArchived
                merged.factsSync = fresh.factsSync
                merged.shareSlug = fresh.shareSlug; merged.shareURL = fresh.shareURL
                merged.unbrandedShareURL = fresh.unbrandedShareURL; merged.publishedRenderID = fresh.publishedRenderID
            }
            result.append(merged)
        }
        for var fresh in remote where !seen.contains(fresh.serverID!) {
            // A UUID collision with an unbound local draft cannot claim it.
            guard !result.contains(where: { $0.id == fresh.id }) else { throw CloudSyncError.invalidResponse }
            fresh.cloudImported = true; fresh.cloudUnavailable = false
            fresh.cloudSyncOwnerID = ownerID
            result.append(fresh)
        }
        return result.sorted {
            if $0.isSample != $1.isSample { return !$0.isSample }
            return $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt
        }
    }
    static func date(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    static func validateMedia(_ url: URL, expiry: String, listingID: UUID, orgID: UUID, now: Date, voice: Bool = false, actorID: UUID? = nil) throws {
        guard let expires = date(expiry), expires > now else { throw CloudSyncError.expired }
        // URL shape and envelope bindings are local preflight only. The gateway
        // verifies HMAC, current membership, exact object custody and budget on
        // every read. Its decoded bearer payload is not proof of ownership.
        if url.host == "rendprop.com" {
            guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil,
                  url.query == nil, url.fragment == nil,
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  components.percentEncodedPath == components.path,
                  components.path.hasPrefix("/private-media/") else { throw CloudSyncError.invalidResponse }
            let token = String(components.path.dropFirst("/private-media/".count))
            let parts = token.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 2, token.utf8.count <= 4096,
                  parts[0].range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil,
                  parts[1].range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw CloudSyncError.invalidResponse }
            let encoded = String(parts[0]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            guard let data = Data(base64Encoded: encoded.padding(toLength: ((encoded.count + 3) / 4) * 4, withPad: "=", startingAt: 0)),
                  data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") == String(parts[0]),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CloudSyncError.invalidResponse }
            var expected: Set<String> = ["v", "actor", "org", "listing", "bucket", "key", "exp"]
            if payload["review"] != nil { expected.insert("review") }
            guard Set(payload.keys) == expected, let version = payload["v"] as? NSNumber,
                  String(cString: version.objCType) != "c", version.stringValue == "1",
                  let actorRaw = payload["actor"] as? String, let actor = UUID(uuidString: actorRaw), actorRaw == actor.uuidString.lowercased(),
                  actorID == nil || actorID == actor,
                  let orgRaw = payload["org"] as? String, UUID(uuidString: orgRaw) == orgID, orgRaw == orgID.uuidString.lowercased(),
                  let bucket = payload["bucket"] as? String, ["uploads", "renders"].contains(bucket),
                  let key = payload["key"] as? String, !key.isEmpty, key.utf8.count <= 1024,
                  let exp = payload["exp"] as? NSNumber, String(cString: exp.objCType) != "c",
                  exp.doubleValue.isFinite, exp.doubleValue.rounded(.towardZero) == exp.doubleValue else { throw CloudSyncError.invalidResponse }
            let deadline = Date(timeIntervalSince1970: exp.doubleValue)
            guard deadline > now, deadline.timeIntervalSince(now) <= 601, expires <= deadline.addingTimeInterval(1) else { throw CloudSyncError.expired }
            if let review = payload["review"] {
                guard payload["listing"] is String,
                      let value = review as? [String: Any], Set(value.keys) == ["owner", "result", "revision"],
                      let owner = value["owner"] as? String, let ownerID = UUID(uuidString: owner), owner == ownerID.uuidString.lowercased(),
                      let result = value["result"] as? String, let resultID = UUID(uuidString: result), result == resultID.uuidString.lowercased(),
                      let revision = value["revision"] as? NSNumber, String(cString: revision.objCType) != "c",
                      revision.doubleValue.isFinite, revision.doubleValue > 0,
                      revision.doubleValue < 2_147_483_647, revision.doubleValue.rounded(.towardZero) == revision.doubleValue else { throw CloudSyncError.invalidResponse }
            }
            let pieces = key.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard pieces.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.rangeOfCharacter(from: CharacterSet(charactersIn: "\\%?#").union(.controlCharacters)) == nil }),
                  !(pieces.last?.lowercased().hasPrefix("contact-") ?? false) else { throw CloudSyncError.invalidResponse }
            if voice {
                guard ["uploads", "renders"].contains(bucket), pieces.count == 3, pieces[0] == "ai-voice",
                      UUID(uuidString: pieces[1]) == orgID, pieces[2].hasSuffix(".mp3"),
                      UUID(uuidString: String(pieces[2].dropLast(4))) != nil,
                      payload["listing"] is NSNull || (payload["listing"] as? String).flatMap(UUID.init(uuidString:)) == listingID else { throw CloudSyncError.invalidResponse }
            } else {
                guard let listing = payload["listing"] as? String, UUID(uuidString: listing) == listingID, listing == listingID.uuidString.lowercased(),
                      pieces[0] == bucket,
                      (pieces.count >= 4 && UUID(uuidString: pieces[1]) == orgID && UUID(uuidString: pieces[2]) == listingID)
                        || (bucket == "renders" && pieces.count == 3 && UUID(uuidString: pieces[1]) == listingID) else { throw CloudSyncError.invalidResponse }
            }
            return
        }
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil,
              url.fragment == nil, let host = url.host,
              host.range(of: "^[a-f0-9]{32}\\.r2\\.cloudflarestorage\\.com$", options: .regularExpression) != nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw CloudSyncError.invalidResponse }
        let pieces = components.percentEncodedPath.split(separator: "/").compactMap { String($0).removingPercentEncoding }
        guard pieces.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.rangeOfCharacter(from: CharacterSet(charactersIn: "\\/%?#").union(.controlCharacters)) == nil }) else { throw CloudSyncError.invalidResponse }
        guard !(pieces.last.map({ $0.lowercased().hasPrefix("contact-") }) ?? false) else { throw CloudSyncError.invalidResponse }
        if voice {
            // Voice objects use the native ai-voice/<org>/<uuid>.mp3 contract.
            // Their listing binding is checked on the trusted result envelope.
            guard pieces.count == 4, pieces[1] == "ai-voice", pieces[2].lowercased() == orgID.uuidString.lowercased(),
                  pieces[3].hasSuffix(".mp3"), UUID(uuidString: String(pieces[3].dropLast(4))) != nil else { throw CloudSyncError.invalidResponse }
        } else {
            guard pieces.count >= 5, ["uploads", "renders"].contains(pieces[1]),
                  pieces[2].lowercased() == orgID.uuidString.lowercased(), pieces[3].lowercased() == listingID.uuidString.lowercased() else { throw CloudSyncError.invalidResponse }
        }
        let params = components.queryItems ?? []
        guard Set(params.map { $0.name.lowercased() }).count == params.count else { throw CloudSyncError.invalidResponse }
        let q = Dictionary(uniqueKeysWithValues: params.map { ($0.name, $0.value ?? "") })
        guard q["X-Amz-Algorithm"] == "AWS4-HMAC-SHA256", q["X-Amz-SignedHeaders"] == "host",
              q["X-Amz-Signature"]?.range(of: "^[a-fA-F0-9]{64}$", options: .regularExpression) != nil,
              let rawSeconds = q["X-Amz-Expires"], let seconds = Int(rawSeconds), seconds > 0, seconds <= 600,
              let stamp = q["X-Amz-Date"], stamp.count == 16,
              !q.keys.contains(where: { ["token", "access_token", "refresh_token", "apikey"].contains($0.lowercased()) }) else { throw CloudSyncError.invalidResponse }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"; formatter.isLenient = false
        guard let issued = formatter.date(from: stamp), formatter.string(from: issued) == stamp,
              issued.addingTimeInterval(Double(seconds)) > now,
              expires <= issued.addingTimeInterval(Double(seconds) + 1) else { throw CloudSyncError.expired }
    }
}
