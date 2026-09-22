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

struct CloudBrand {
    let userID: UUID
    let orgID: UUID
    let spaceType: String
    let fields: [String: String]
}

/// The actual asynchronous create handoff used by AppModel. Tests can suspend
/// its create closure to exercise edits, deletion and account changes in flight.
@MainActor enum CloudDraftCreation {
    struct Identity: Equatable { let userID: String?; let revision: UInt64 }
    static func fingerprint(_ listing: Listing) throws -> String {
        let facts: [String: Any] = ["address": listing.address, "space": listing.spaceType.rawValue,
            "beds": listing.beds, "baths": listing.baths, "sqft": listing.sqft, "price": listing.price.cents,
            "tagline": listing.tagline ?? "", "details": listing.details ?? [:], "zillow": listing.zillowURL ?? "",
            "lat": listing.latitude as Any? ?? NSNull(), "lng": listing.longitude as Any? ?? NSNull(),
            "sold": listing.soldAt?.timeIntervalSince1970 as Any? ?? NSNull(), "indexing": listing.allowSearchIndexing as Any? ?? NSNull()]
        let data = try JSONSerialization.data(withJSONObject: facts, options: [.sortedKeys])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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
        try Task.checkCancellation()
        guard activeIdentity() == identity else { throw CloudSyncError.identityChanged }
        guard var latest = current() else {
            await deleteRemoved(created.serverID ?? created.id)
            throw CancellationError()
        }
        if let existing = latest.serverID { return existing }
        // Preserve every current field and device file. Even a replay may have
        // older facts, so a PATCH of the newest local truth follows binding.
        latest.serverID = created.serverID ?? created.id
        latest.serverOrgID = created.serverOrgID
        latest.cloudSyncOwnerID = identity.userID.flatMap(UUID.init(uuidString:))
        latest.cloudDetachedServerID = nil
        latest.cloudUnavailable = false
        if created.cloudCreateReplayed == true, let original = snapshot.cloudCreateFingerprint, try fingerprint(latest) == original {
            // A receipt was lost and the office has since edited the row.
            // With no newer phone edit, adopt those facts instead of PATCHing
            // the old create payload back over the office's work.
            latest.address = created.address; latest.beds = created.beds; latest.baths = created.baths
            latest.sqft = created.sqft; latest.price = created.price; latest.tagline = created.tagline
            latest.details = created.details; latest.zillowURL = created.zillowURL; latest.soldAt = created.soldAt
            latest.latitude = created.latitude; latest.longitude = created.longitude
            latest.spaceTypeRaw = created.spaceTypeRaw; latest.allowSearchIndexing = created.allowSearchIndexing
            latest.needsServerSync = false
        } else {
            latest.needsServerSync = true
        }
        latest.cloudCreateFingerprint = nil; latest.cloudCreateReplayed = nil
        save(latest)
        return latest.serverID!
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
              renders.allSatisfy({ $0.listing_id == listingID }), photos.allSatisfy({ $0.listing_id == listingID }),
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

    func checked(listingID: UUID, orgID: UUID, offset: Int, now: Date = Date()) throws -> Self {
        guard org_id == orgID, listing_id == listingID, photos.count <= 100, videos.count <= 100,
              unavailable_count >= 0, next_offset == nil || (next_offset == offset + 50 && offset < 10000),
              Set(photos.map(\.id)).count == photos.count, Set(videos.map(\.id)).count == videos.count else { throw CloudSyncError.invalidResponse }
        for photo in photos {
            guard photo.listing_id == listingID else { throw CloudSyncError.invalidResponse }
            try CloudListingMerge.validateMedia(photo.url, expiry: photo.expires_at, listingID: listingID, orgID: orgID, now: now)
            if let original = photo.original_url { try CloudListingMerge.validateMedia(original, expiry: photo.expires_at, listingID: listingID, orgID: orgID, now: now) }
        }
        for video in videos {
            guard video.listing_id == listingID else { throw CloudSyncError.invalidResponse }
            try CloudListingMerge.validateMedia(video.url, expiry: video.expires_at, listingID: listingID, orgID: orgID, now: now)
        }
        return self
    }
}

enum CloudSyncError: LocalizedError {
    case invalidResponse, identityChanged, incomplete, expired, cloudMissing
    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Rendprop couldn't read this cloud update. Pull to refresh and try again."
        case .identityChanged: return "The account changed while syncing. Refresh from your current account."
        case .incomplete: return "The cloud library changed while loading. Your saved work is safe; pull to refresh again."
        case .expired: return "This private file link expired. Refresh the cloud files and try again."
        case .cloudMissing: return "This listing was removed from the cloud or your team access changed. Your files on this iPhone are still available."
        }
    }
}

enum CloudListingMerge {
    /// The remote input must be the COMPLETE, identity-checked set from the RLS
    /// read. Never call with one page or with a failed/empty fallback response.
    static func merge(local: [Listing], remote: [Listing], protected: Set<UUID>, ownerID: UUID? = nil) throws -> [Listing] {
        guard Set(remote.compactMap(\.serverID)).count == remote.count,
              remote.allSatisfy({ !$0.isSample && $0.serverID != nil && $0.serverOrgID != nil }) else { throw CloudSyncError.invalidResponse }
        let remoteByID = Dictionary(uniqueKeysWithValues: remote.map { ($0.serverID!, $0) })
        var seen = Set<UUID>()
        var result: [Listing] = []
        for existing in local {
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
                merged.soldAt = fresh.soldAt; merged.zillowURL = fresh.zillowURL
                merged.latitude = fresh.latitude; merged.longitude = fresh.longitude
                merged.allowSearchIndexing = fresh.allowSearchIndexing
                merged.status = fresh.status
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
    static func validateMedia(_ url: URL, expiry: String, listingID: UUID, orgID: UUID, now: Date, voice: Bool = false) throws {
        guard let expires = date(expiry), expires > now else { throw CloudSyncError.expired }
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil,
              url.fragment == nil, let host = url.host,
              host.range(of: "^[a-f0-9]{32}\\.r2\\.cloudflarestorage\\.com$", options: .regularExpression) != nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw CloudSyncError.invalidResponse }
        let pieces = components.percentEncodedPath.split(separator: "/").compactMap { String($0).removingPercentEncoding }
        guard pieces.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.rangeOfCharacter(from: CharacterSet(charactersIn: "\\/%?#").union(.controlCharacters)) == nil }) else { throw CloudSyncError.invalidResponse }
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
