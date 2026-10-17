import Foundation

@MainActor extension AppModel {
    /// Account-scoped UX choice. A remote refresh never erases an offline choice.
    func syncRealEstateRole() async {
        guard let owner = AuthStore.shared.userID else { return }
        guard !realEstateRoleSyncOwners.contains(owner) else { return }
        realEstateRoleSyncOwners.insert(owner)
        defer { realEstateRoleSyncOwners.remove(owner) }
        let revision = AuthStore.shared.syncSessionRevision
        RealEstateRoleStore.claimOnboarding(owner: owner)
        do {
            var writes = 0
            while RealEstateRoleStore.isDirty(owner: owner), writes < 3 {
                let role = RealEstateRoleStore.current(owner: owner)
                writes += 1
                try await api.updateRealEstateRole(role)
                guard AuthStore.shared.userID == owner, AuthStore.shared.syncSessionRevision == revision else { return }
                RealEstateRoleStore.markSynced(role, owner: owner)
            }
            if writes == 0 {
                let remote = try await api.realEstateRole()
                guard AuthStore.shared.userID == owner, AuthStore.shared.syncSessionRevision == revision else { return }
                RealEstateRoleStore.acceptCloud(remote, owner: owner)
            }
        } catch { /* Retain the local choice; foreground/settings retry it. */ }
    }

    func setClientContactDraft(_ contact: ListingClientContact, photoPath: String?, photoDirty: Bool, for id: UUID) throws {
        guard let i = listings.firstIndex(where: { $0.id == id }), !listings[i].isSample,
              isInSelectedWorkspace(listings[i]), listings[i].cloudUnavailable != true else { throw ClientContactError.changed }
        try ClientContactPolicy.validate(contact)
        listings[i].clientContact = contact
        listings[i].clientPhotoRelPath = photoPath
        listings[i].clientPhotoDirty = photoDirty
        listings[i].clientContactDirty = true
    }

    /// Hydration is separate from property facts; failure never clears a saved card.
    func refreshClientContact(for id: UUID, discardDraft: Bool = false) async throws {
        guard let listing = listings.first(where: { $0.id == id }), !listing.isSample,
              isInSelectedWorkspace(listing), listing.cloudUnavailable != true else { throw ClientContactError.changed }
        guard let server = listing.serverID else { return }
        if listing.clientContactDirty == true && !discardDraft { return }
        let actor = AuthStore.shared.userID, revision = AuthStore.shared.syncSessionRevision
        let selected = WorkspaceContext.selectedOrgID
        guard !Config.useLiveBackend || selected == listing.serverOrgID else { throw ClientContactError.changed }
        let org = listing.serverOrgID ?? selected ?? UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        let remote = try await api.clientContact(listingID: server, orgID: org)
        guard AuthStore.shared.userID == actor, AuthStore.shared.syncSessionRevision == revision,
              WorkspaceContext.selectedOrgID == selected,
              let i = listings.firstIndex(where: { $0.id == id }), listings[i].serverID == server,
              (discardDraft || listings[i].clientContactDirty != true) else { throw ClientContactError.changed }
        // A photo from a replaced card cannot stand in for the client's current photo.
        if listings[i].clientContact?.photoAssetID != remote?.photoAssetID {
            listings[i].clientPhotoRelPath = nil
        }
        listings[i].clientContact = remote
        listings[i].clientContactLoaded = true
        listings[i].clientContactDirty = false
        listings[i].clientPhotoDirty = false
    }

    /// Before publishing, the actual server card is read, then a dirty local card
    /// is saved with compare-and-swap. A conflict or upload failure blocks publishing.
    func syncClientContactBeforePublish(_ id: UUID, requireClient: Bool = false) async throws {
        guard !clientContactSyncInFlight.contains(id) else { throw ClientContactError.busy }
        clientContactSyncInFlight.insert(id)
        defer { clientContactSyncInFlight.remove(id) }
        guard let listing = listings.first(where: { $0.id == id }), !listing.isSample,
              isInSelectedWorkspace(listing), listing.cloudUnavailable != true else { throw ClientContactError.changed }
        let actor = AuthStore.shared.userID, revision = AuthStore.shared.syncSessionRevision
        let selected = WorkspaceContext.selectedOrgID
        let usesLiveAPI = api is LiveAPIClient
        let server = usesLiveAPI ? try await ensureServerListing(listing) : (listing.serverID ?? listing.id)
        guard let snapshot = listings.first(where: { $0.id == id }) else { throw ClientContactError.changed }
        guard !usesLiveAPI || snapshot.serverOrgID == selected else { throw ClientContactError.changed }
        let org = snapshot.serverOrgID ?? selected ?? UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        func check() throws {
            try Task.checkCancellation()
            guard AuthStore.shared.userID == actor, AuthStore.shared.syncSessionRevision == revision,
                  WorkspaceContext.selectedOrgID == selected,
                  let latest = listings.first(where: { $0.id == id }), (!usesLiveAPI || latest.serverID == server),
                  isInSelectedWorkspace(latest), latest.cloudUnavailable != true else { throw ClientContactError.changed }
        }
        try check()
        if snapshot.clientContactDirty == true, let draft = snapshot.clientContact {
            var acknowledgementSnapshot = snapshot.clientContact
            let saved = try await ClientContactCommit.resolve(snapshot: .init(contact: draft,
                photoPath: snapshot.clientPhotoRelPath, photoDirty: snapshot.clientPhotoDirty == true), listingID: server,
                isIdentityCurrent: { (try? check()) != nil },
                isDraftCurrent: { self.listings.first(where: { $0.id == id }).map {
                    ClientContactPolicy.canApply(snapshot: snapshot.clientContact, latest: $0.clientContact,
                        snapshotPhoto: snapshot.clientPhotoRelPath, latestPhoto: $0.clientPhotoRelPath) } ?? false },
                fetch: { try await self.api.clientContact(listingID: server, orgID: org) },
                uploadPhoto: { path in
                    let photo = FileStore.url(fromRelativePath: path)
                    let bytes = FileStore.fileSize(photo)
                    guard bytes > 0, bytes <= 2_000_000 else { throw ClientContactError.pendingPhoto }
                    let asset = try await DirectUploader.uploadPhoto(fileURL: photo, listingID: server,
                        role: "contact_photo", contentType: "image/jpeg", keyPrefix: "client-contact-photo", api: self.api)
                    guard let assetID = UUID(uuidString: asset) else { throw ClientContactError.invalidResponse }
                    return assetID
                }, onPhotoUploaded: { asset in
                    try check()
                    guard let i = self.listings.firstIndex(where: { $0.id == id }),
                          ClientContactPolicy.canApply(snapshot: snapshot.clientContact, latest: self.listings[i].clientContact,
                            snapshotPhoto: snapshot.clientPhotoRelPath, latestPhoto: self.listings[i].clientPhotoRelPath) else { throw ClientContactError.changed }
                    // An unchanged local draft owns this asset receipt. A new photo
                    // or Remove clears the ID; lost PUT replies reuse it on retry.
                    self.listings[i].clientContact?.photoAssetID = asset
                    self.listings[i].clientPhotoDirty = false
                    acknowledgementSnapshot = self.listings[i].clientContact
                }, save: { try await self.api.saveClientContact($0, listingID: server, orgID: org) })
            try check()
            guard let i = listings.firstIndex(where: { $0.id == id }) else { throw ClientContactError.changed }
            let acknowledgement = try ClientContactPolicy.acknowledge(saved: saved, snapshot: acknowledgementSnapshot,
                latest: listings[i].clientContact, snapshotPhoto: snapshot.clientPhotoRelPath, latestPhoto: listings[i].clientPhotoRelPath)
            listings[i].clientContact = acknowledgement.contact
            guard acknowledgement.clearsDirty else { throw ClientContactError.changed }
            listings[i].clientContactDirty = false
            listings[i].clientPhotoDirty = false
            listings[i].clientContactLoaded = true
        } else {
            let remote = try await api.clientContact(listingID: server, orgID: org)
            try check()
            guard let i = listings.firstIndex(where: { $0.id == id }), listings[i].clientContactDirty != true else { throw ClientContactError.changed }
            if listings[i].clientContact?.photoAssetID != remote?.photoAssetID { listings[i].clientPhotoRelPath = nil }
            listings[i].clientContact = remote
            listings[i].clientContactLoaded = true
        }
        if ClientContactPolicy.requiresChoice(isProducer: requireClient, contact: listings.first(where: { $0.id == id })?.clientContact) {
            throw ClientContactError.clientRequired
        }
    }
}
