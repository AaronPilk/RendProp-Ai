import Foundation

/// Explicit removal is the only cloud-gallery subtraction path. An imported
/// partial gallery must never become a full replacement of remote selections.
@MainActor enum PhotoListingRemovalCoordinator {
    private static let journal = PhotoListingRemovalJournal(directory:
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])

    enum Failure: Error, LocalizedError {
        case missingIdentity, ambiguousIdentity, selectionChanged
        var errorDescription: String? {
            switch self {
            case .missingIdentity: return "Refresh this home's cloud photos before removing this selection. Your saved originals and edits are kept."
            case .ambiguousIdentity: return "More than one cloud photo matches these bytes. Refresh the cloud gallery before choosing which photo to remove."
            case .selectionChanged: return "This home's photo selection changed. Reopen the photo and review the current selection before trying again."
            }
        }
    }

    struct Confirmed {
        let operation: PhotoGalleryRemovalOperation
        let reply: PhotoGalleryRemovalReply
    }

    /// A lost removal reply must also fence later append passes after relaunch.
    /// Read only exact account/library/listing/family journals; no URL or file
    /// name is treated as cloud authority.
    static func hasPending(directory: URL, localListingID: UUID, serverListingID: UUID,
                           actorID: UUID, libraryOrgID: UUID,
                           store: PhotoListingRemovalJournal? = nil) throws -> Bool {
        let index = try PhotoVersionHistory.load(directory: directory)
        let store = store ?? journal
        for family in Set(index.versions.values.map(\.familyID)) {
            let scope = PhotoListingRemovalJournal.Scope(actorID: actorID, libraryOrgID: libraryOrgID,
                localListingID: localListingID, serverListingID: serverListingID, familyID: family)
            if try store.load(scope: scope) != nil { return true }
        }
        return false
    }

    static func remove(versionID: String, directory: URL, localListingID: UUID, serverListingID: UUID,
                       actorID: UUID, libraryOrgID: UUID, api: any ListingGalleryRemovalAPI,
                       requireIdentity: @MainActor () throws -> Void,
                       store: PhotoListingRemovalJournal? = nil,
                       references: CloudPhotoReferences = .shared) async throws -> Confirmed {
        try requireIdentity()
        let index = try PhotoVersionHistory.load(directory: directory)
        guard let version = index.versions[versionID], index.isSelectedForListing(versionID) else {
            throw Failure.selectionChanged
        }
        let store = store ?? journal
        let scope = PhotoListingRemovalJournal.Scope(actorID: actorID, libraryOrgID: libraryOrgID,
            localListingID: localListingID, serverListingID: serverListingID, familyID: version.familyID)
        let operation: PhotoGalleryRemovalOperation
        if let saved = try store.load(scope: scope) {
            operation = saved
        } else {
            let snapshot = try await api.gallerySelection(serverID: serverListingID, libraryOrgID: libraryOrgID)
            try requireIdentity()
            guard snapshot.listingID == serverListingID, snapshot.libraryOrgID == libraryOrgID else {
                throw CloudSyncError.identityChanged
            }
            var requested = Set<UUID>()
            for member in index.history(for: versionID) {
                try requireIdentity()
                let file = directory.appendingPathComponent(member.imageFile)
                guard FileStore.fileSize(file) > 0 else { continue }
                if let known = try await references.galleryAssetID(fileURL: file, ownerID: actorID,
                        orgID: libraryOrgID, listingID: serverListingID, physicalOrgID: snapshot.orgID) {
                    requested.insert(known)
                } else {
                    // This fallback handles older imported files with no native
                    // gallery receipt. Match exact immutable bytes, never a
                    // photos-table UUID, filename, thumbnail or signed URL.
                    let measured = await Task.detached(priority: .userInitiated) {
                        (DirectUploader.sha256(of: file), FileStore.fileSize(file))
                    }.value
                    try requireIdentity()
                    let matches = snapshot.galleryAssets.filter { $0.sha256 == measured.0 && $0.bytes == measured.1 }
                    guard matches.count <= 1 else { throw Failure.ambiguousIdentity }
                    if let match = matches.first {
                        try await references.saveGalleryAssetID(assetID: match.assetID, fileURL: file,
                            ownerID: actorID, orgID: libraryOrgID, listingID: serverListingID,
                            expectedSHA256: match.sha256, expectedBytes: match.bytes)
                        requested.insert(match.assetID)
                    }
                }
            }
            try requireIdentity()
            guard !requested.isEmpty, requested.count <= 100 else { throw Failure.missingIdentity }
            let ids = requested.sorted { $0.uuidString < $1.uuidString }
            operation = try store.begin(.init(operationID: UUID(), actorID: actorID, libraryOrgID: libraryOrgID,
                localListingID: localListingID, serverListingID: serverListingID, familyID: version.familyID,
                selectedVersionID: versionID, requestedAssetIDs: ids,
                expectedGalleryAssetIDs: snapshot.galleryAssetIDs, expectedMainPhotoKey: snapshot.mainPhotoKey))
        }
        try requireIdentity()
        let reply: PhotoGalleryRemovalReply
        do { reply = try await api.removeGalleryAssets(operation) }
        catch {
            // This exact server code is a definitive pre-mutation CAS refusal.
            // Network/other refusals retain the same immutable pending request.
            if let error = error as? APIError, error.status == 409 && error.code == "gallery_selection_changed" {
                try store.finish(operation)
            }
            throw error
        }
        try requireIdentity()
        guard reply.operationID == operation.operationID,
              reply.selection.listingID == serverListingID, reply.selection.libraryOrgID == libraryOrgID,
              reply.requestedAssetIDs == operation.requestedAssetIDs,
              Set(reply.removedAssetIDs).isSubset(of: Set(operation.requestedAssetIDs)) else {
            throw PhotoListingRemovalJournal.Failure.mismatchedOperation
        }
        // A replay acknowledges its old immutable operation, not a later
        // re-added selection. Never use it to remove that newer local choice.
        guard let current = reply.selection.galleryAssetIDs,
              Set(current).isDisjoint(with: Set(operation.requestedAssetIDs)),
              operation.selectedVersionID == versionID else {
            try store.finish(operation)
            throw Failure.selectionChanged
        }
        return Confirmed(operation: operation, reply: reply)
    }

    static func finish(_ confirmed: Confirmed, store: PhotoListingRemovalJournal? = nil) throws {
        try (store ?? journal).finish(confirmed.operation)
    }
}
