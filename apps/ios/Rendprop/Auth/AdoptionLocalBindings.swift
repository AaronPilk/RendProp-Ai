import Foundation

/// Non-secret metadata in the SAME atomic snapshot as the user's listings.
/// It is not server authorization: only an exact verified adoption receipt may
/// apply it. No photos, tokens or editable listing text are copied here.
struct AdoptionLocalBindings: Codable, Equatable {
    struct Entry: Codable, Equatable {
        let localID: UUID
        let serverID: UUID
        let shareSlug: String?
        let shareURL: String?
        let unbrandedShareURL: String?
        let publishedRenderID: UUID?
    }
    let version: Int
    let operationID: UUID
    let sourceUserID: UUID
    let destinationUserID: UUID
    var entries: [Entry]
    var confirmedOrgID: UUID?
    var appliedToCurrentState = false
    /// Includes offline-only properties so signing in preserves their production drafts.
    /// Optional for bindings written before the production companion shipped.
    var productionLocalIDs: [UUID]? = nil
    var productionTransferred: Bool? = nil
    /// Profile text/portrait and paid-request safety markers transfer only once
    /// after the same verified receipt. Optional for older phone snapshots.
    var ownedIdentityTransferred: Bool? = nil
    var personalCardDisposition: String? = nil

    enum Failure: Error { case invalid, conflict, tooLarge }

    func matches(_ pending: AnonymousAdoptionRecovery.Pending) -> Bool {
        operationID == pending.operationID && sourceUserID == pending.sourceUserID
            && destinationUserID == pending.destinationUserID
    }

    func validate() throws {
        guard version == 1, sourceUserID != destinationUserID,
              !appliedToCurrentState || confirmedOrgID != nil,
              Set(entries.map(\.localID)).count == entries.count,
              Set(entries.map(\.serverID)).count == entries.count,
              personalCardDisposition == nil || ["source_copied", "destination_preserved", "no_source_card"].contains(personalCardDisposition!),
              productionLocalIDs == nil || Set(productionLocalIDs!).count == productionLocalIDs!.count else { throw Failure.invalid }
        // Metadata only: cap optional sign-in's journal, never truncate a
        // library or block capture. A large library can keep using its source
        // session until a deliberate recovery path is available.
        guard try JSONEncoder().encode(self).count <= 1_048_576 else { throw Failure.tooLarge }
    }

    static func capture(_ pending: AnonymousAdoptionRecovery.Pending,
                        listings: [Listing]) throws -> Self {
        // Local custody can include drafts preserved from an earlier login.
        // A guest's receipt authorizes only this guest's local production IDs.
        let owned = listings.filter { !$0.isSample && ($0.cloudSyncOwnerID == nil || $0.cloudSyncOwnerID == pending.sourceUserID) }
        var value = Self(version: 1, operationID: pending.operationID,
                         sourceUserID: pending.sourceUserID, destinationUserID: pending.destinationUserID,
                         entries: owned.filter { $0.serverID != nil }.map {
            Entry(localID: $0.id, serverID: $0.serverID!, shareSlug: $0.shareSlug,
                  shareURL: $0.shareURL, unbrandedShareURL: $0.unbrandedShareURL,
                  publishedRenderID: $0.publishedRenderID)
        }, confirmedOrgID: nil)
        value.productionLocalIDs = owned.map(\.id)
        try value.validate()
        return value
    }

    /// Older receipts may have captured a retained foreign account's draft.
    /// Keep absent IDs as history, but exclude every present sample/foreign row
    /// before restoring identities or production caches. Never expand a journal.
    func scopedToLocalCustody(_ listings: [Listing]) -> Self {
        let excluded = Set(listings.filter { $0.isSample || ($0.cloudSyncOwnerID != nil && $0.cloudSyncOwnerID != sourceUserID && $0.cloudSyncOwnerID != destinationUserID) }.map(\.id))
        var value = self
        value.entries = entries.filter { !excluded.contains($0.localID) }
        value.productionLocalIDs = productionLocalIDs.map { $0.filter { !excluded.contains($0) } }
        return value
    }

    func blocks(_ localID: UUID, currentUserID: UUID?) -> Bool {
        !appliedToCurrentState && currentUserID != sourceUserID && (entries.contains { $0.localID == localID } || productionLocalIDs?.contains(localID) == true)
    }

    /// Keychain removal may fail AFTER a successful rebind. If the person then
    /// switches away, retain the latest links for the same receipt-bound IDs,
    /// not a stale earlier publication. A new foreign ID is never adopted here.
    func detaching(_ listings: [Listing], owner: UUID?) -> Self {
        var value = self
        if appliedToCurrentState, owner == destinationUserID {
            value.entries = entries.map { original in
                guard let current = listings.first(where: { $0.id == original.localID && !$0.isSample }),
                      current.serverID == original.serverID else { return original }
                return Entry(localID: current.id, serverID: original.serverID, shareSlug: current.shareSlug,
                    shareURL: current.shareURL, unbrandedShareURL: current.unbrandedShareURL,
                    publishedRenderID: current.publishedRenderID)
            }
        }
        value.appliedToCurrentState = false
        return value
    }

    /// Merge ONLY identities into surviving local listings. Edits/new local
    /// media remain; a deleted listing is never resurrected, and a foreign or
    /// newly created server identity is never silently overwritten.
    func restoring(_ listings: [Listing], pending: AnonymousAdoptionRecovery.Pending,
                   currentUserID: UUID?, orgID: UUID) throws -> [Listing] {
        try validate()
        guard matches(pending), currentUserID == destinationUserID,
              confirmedOrgID == nil || confirmedOrgID == orgID else { throw Failure.conflict }
        let originals = Dictionary(uniqueKeysWithValues: entries.map { ($0.localID, $0) })
        return try listings.map { current in
            guard !current.isSample, let original = originals[current.id] else { return current }
            guard current.serverID == nil || current.serverID == original.serverID else { throw Failure.conflict }
            var restored = current
            restored.serverID = original.serverID
            restored.shareSlug = original.shareSlug
            restored.shareURL = original.shareURL
            restored.unbrandedShareURL = original.unbrandedShareURL
            restored.publishedRenderID = original.publishedRenderID
            // A local edit while IDs were temporarily cleared cannot mark its
            // usual dirty flag. A later PATCH must include those current edits.
            restored.needsServerSync = true
            return restored
        }
    }
}
